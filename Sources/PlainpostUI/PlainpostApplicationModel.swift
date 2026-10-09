import CryptoKit
import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostServiceIPC
import OSLog
#if os(macOS)
import ServiceManagement
#endif

private let packagedServiceLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "packaged-service"
)

public struct PlainpostNotificationOpenRequest: Equatable, Sendable {
    public let id: UUID
    public let destination: PlainpostNotificationOpenDestination

    public init(id: UUID = UUID(), destination: PlainpostNotificationOpenDestination) {
        self.id = id
        self.destination = destination
    }
}

@MainActor public final class PlainpostApplicationModel: ObservableObject {
    public static let unlockReason = "Unlock Plainpost to access your saved mail credentials."

    @Published public private(set) var runtime: PlainpostAppRuntime?
    @Published public private(set) var runtimeError: String?
    @Published public private(set) var vaultLaunchState: PlainpostVaultLaunchState = .checking
    @Published public private(set) var notificationOpenRequest: PlainpostNotificationOpenRequest?
    /// Whether the background service answering on the shared Mach name is
    /// this installation's own.
    @Published public private(set) var serviceOwnership: PlainpostServiceOwnership = .unknown
    /// Set when an explicit Lock Vault failed; the vault then still counts
    /// as unlocked and the runtime is restored.
    @Published public private(set) var lockVaultError: String?
    nonisolated public static let lockVaultFailureMessage = "Plainpost could not lock the vault. Try again."
    /// Set when "Start Over with Saved Sign-ins" did not finish and the key
    /// is still missing.
    @Published public private(set) var vaultStartOverError: String?
    /// Set once "Start Over with Saved Sign-ins" opened a fresh vault; the
    /// Mac app then opens Settings, where each account signs in again.
    @Published public private(set) var startedOverWithSavedSignIns = false
    nonisolated public static let vaultStartOverFailureMessage =
        "Plainpost couldn't finish starting over. Your mail on this Mac is unchanged. Try again."

    private let makeRuntime: @MainActor () throws -> PlainpostAppRuntime
    private let makeReadOnlyRuntime: @MainActor () throws -> PlainpostAppRuntime
    private let monitor: @MainActor (PlainpostAppRuntime) async throws -> Void
    private let shutdownRuntime: @MainActor (PlainpostAppRuntime) async -> Void
    private let purgeManagedDataAction: @Sendable () async throws -> Data
    private let prepareServiceAction: @Sendable () async -> Void
    private let vaultReadiness: @Sendable () async -> PlainpostVaultLaunchState
    private let unlockVaultAction: @Sendable (String) async -> PlainpostVaultLaunchState
    private let startOverVaultAction: @Sendable (String) async -> PlainpostVaultLaunchState
    private let lockVaultAction: @Sendable () async -> Void
    #if DEBUG
    private let acceptanceReadinessBootstrap:
        (@Sendable (PlainpostVaultLaunchState) async -> PlainpostVaultLaunchState)?
    #endif
    private var monitoringTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var runtimeShutdownTask: Task<Void, Never>?
    private var runtimeAccessTask: Task<Void, Never>?
    private var notificationOpenTask: Task<Void, Never>?
    private var lockedVaultWatchTask: Task<Void, Never>?
    private var unavailableServiceWatchTask: Task<Void, Never>?
    private var serviceUnavailableAttempts = 0
    /// Delays between readiness passes while the service is unavailable.
    var serviceUnavailableBackoff: [Duration] = [
        .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
    ]
    /// How often a locked vault is re-read, so an unlock from the CLI or
    /// another client resumes the runtime without a window.
    var lockedVaultPollInterval: Duration = .seconds(15)
    /// The explicit Lock Vault call, which reports failure. Shutdown and
    /// purge keep the best-effort `lockVaultAction`.
    var explicitLockAction: (@Sendable () async throws -> Void)?
    private var pendingNotificationOpenToken: String?
    private var hasStarted = false
    private var lifecycleGeneration: UInt64 = 0
    private var teardownInProgress = false
    private var retryAfterTeardown = false
    private var shutdownInProgress = false
    @Published public private(set) var accountReadOnly = false
    private var runtimeReadOnly: Bool?
    /// The app's connection to PlainpostService, shared with the account
    /// model so Node session traffic after activation, and the broker
    /// invalidation after enrollment or replacement, use the service broker.
    public private(set) var nodeSessionClient: (any PlainpostServiceClientProtocol)?

    public convenience init(
        configuration: PlainpostAppRuntimeConfiguration = PlainpostAppRuntimeConfiguration(),
        startsImmediately: Bool = true
    ) {
        let serviceOwner = DefaultGUIServiceOwner(configuration: configuration)
        self.init(
            makeRuntime: { try serviceOwner.makeRuntime() },
            makeReadOnlyRuntime: { try serviceOwner.makeRuntime(accountAccess: .cachedReadOnly) },
            monitor: { runtime in try await runtime.monitorMail() },
            purgeManagedData: { try await serviceOwner.purgeManagedData() },
            prepareService: { await serviceOwner.prepareService() },
            vaultReadiness: { await serviceOwner.evaluate() },
            unlockVault: { reason in await serviceOwner.unlock(reason: reason) },
            startOverVault: { reason in await serviceOwner.startOver(reason: reason) },
            lockVault: { await serviceOwner.lock() }, initializeImmediately: false)
        nodeSessionClient = configuration.serviceClient
        explicitLockAction = { try await serviceOwner.lockReportingFailure() }
        serviceOwner.ownershipRelay.handler = { [weak self] ownership in
            self?.serviceOwnership = ownership
        }
        if startsImmediately { start() }
    }

#if DEBUG
    public convenience init(
        configuration: PlainpostAppRuntimeConfiguration,
        acceptanceReadinessBootstrap:
            @escaping @Sendable (PlainpostVaultLaunchState) async -> PlainpostVaultLaunchState
    ) {
        let gate = PlainpostVaultReadinessGate(serviceClient: configuration.serviceClient)
        self.init(
            makeRuntime: { try PlainpostAppRuntime(configuration: configuration) },
            monitor: { runtime in try await runtime.monitorMail() },
            vaultReadiness: { await gate.evaluate() },
            unlockVault: { reason in await gate.unlock(reason: reason) },
            startOverVault: { reason in await gate.startOver(reason: reason) },
            lockVault: { try? await configuration.serviceClient.lock() },
            acceptanceReadinessBootstrap: acceptanceReadinessBootstrap, initializeImmediately: false
        )
        start()
    }

    public static func debugMailboxUIAcceptance() -> PlainpostApplicationModel {
        PlainpostApplicationModel(
            makeRuntime: {
                preconditionFailure("Mailbox UI acceptance must not construct a runtime.")
            }, monitor: { _ in }, vaultReadiness: { .serviceUnavailable },
            initializeImmediately: false)
    }
#endif

    init(
        makeRuntime: @escaping @MainActor () throws -> PlainpostAppRuntime,
        makeReadOnlyRuntime: (@MainActor () throws -> PlainpostAppRuntime)? = nil,
        monitor: @escaping @MainActor (PlainpostAppRuntime) async throws -> Void,
        shutdownRuntime: @escaping @MainActor (PlainpostAppRuntime) async -> Void = {
            runtime in await runtime.shutdown()
        },
        purgeManagedData: @escaping @Sendable () async throws -> Data = {
            throw PlainpostError.notFound("Managed account purge is unavailable.")
        },
        prepareService: @escaping @Sendable () async -> Void = {},
        vaultReadiness: @escaping @Sendable () async -> PlainpostVaultLaunchState = { .ready },
        unlockVault: @escaping @Sendable (String) async -> PlainpostVaultLaunchState = { _ in .ready
        },
        startOverVault: @escaping @Sendable (String) async -> PlainpostVaultLaunchState = { _ in .keyMissing },
        lockVault: @escaping @Sendable () async -> Void = {}, initializeImmediately: Bool = true
    ) {
        self.makeRuntime = makeRuntime
        self.makeReadOnlyRuntime = makeReadOnlyRuntime ?? makeRuntime
        self.monitor = monitor
        self.shutdownRuntime = shutdownRuntime
        purgeManagedDataAction = purgeManagedData
        prepareServiceAction = prepareService
        self.vaultReadiness = vaultReadiness
        unlockVaultAction = unlockVault
        startOverVaultAction = startOverVault
        lockVaultAction = lockVault
        #if DEBUG
        acceptanceReadinessBootstrap = nil
        #endif
        if initializeImmediately {
            hasStarted = true
            vaultLaunchState = .ready
            initializeRuntime()
        }
    }

#if DEBUG
    init(
        makeRuntime: @escaping @MainActor () throws -> PlainpostAppRuntime,
        makeReadOnlyRuntime: (@MainActor () throws -> PlainpostAppRuntime)? = nil,
        monitor: @escaping @MainActor (PlainpostAppRuntime) async throws -> Void,
        shutdownRuntime: @escaping @MainActor (PlainpostAppRuntime) async -> Void = {
            runtime in await runtime.shutdown()
        },
        purgeManagedData: @escaping @Sendable () async throws -> Data = {
            throw PlainpostError.notFound("Managed account purge is unavailable.")
        },
        prepareService: @escaping @Sendable () async -> Void = {},
        vaultReadiness: @escaping @Sendable () async -> PlainpostVaultLaunchState = { .ready },
        unlockVault: @escaping @Sendable (String) async -> PlainpostVaultLaunchState = { _ in .ready
        },
        startOverVault: @escaping @Sendable (String) async -> PlainpostVaultLaunchState = { _ in .keyMissing },
        lockVault: @escaping @Sendable () async -> Void = {},
        acceptanceReadinessBootstrap:
            @escaping @Sendable (PlainpostVaultLaunchState) async -> PlainpostVaultLaunchState,
        initializeImmediately: Bool = true
    ) {
        self.makeRuntime = makeRuntime
        self.makeReadOnlyRuntime = makeReadOnlyRuntime ?? makeRuntime
        self.monitor = monitor
        self.shutdownRuntime = shutdownRuntime
        purgeManagedDataAction = purgeManagedData
        prepareServiceAction = prepareService
        self.vaultReadiness = vaultReadiness
        unlockVaultAction = unlockVault
        startOverVaultAction = startOverVault
        lockVaultAction = lockVault
        self.acceptanceReadinessBootstrap = acceptanceReadinessBootstrap
        if initializeImmediately {
            hasStarted = true
            vaultLaunchState = .ready
            initializeRuntime()
        }
    }
#endif

    deinit {
        monitoringTask?.cancel()
        lockedVaultWatchTask?.cancel()
        unavailableServiceWatchTask?.cancel()
        readinessTask?.cancel()
        runtimeAccessTask?.cancel()
        notificationOpenTask?.cancel()
    }

    public func start(readOnly: Bool = false) {
        accountReadOnly = readOnly
        if hasStarted {
            if runtime != nil, runtimeReadOnly != readOnly {
                replaceRuntimeForAccountAccess()
                return
            }
            reconcileMailMonitoring()
            return
        }
        hasStarted = true
        beginReadinessCheck()
    }

    public func retry() {
        guard !shutdownInProgress else { return }
        if teardownInProgress {
            hasStarted = true
            retryAfterTeardown = true
            return
        }
        if vaultLaunchState == .ready {
            if runtime == nil {
                initializeRuntime(isRetry: true)
            } else {
                beginReadinessCheck(isRetry: true)
            }
        } else {
            hasStarted = true
            beginReadinessCheck(isRetry: true)
        }
    }

    public func unlockVault() {
        guard vaultLaunchState == .locked, !teardownInProgress, !shutdownInProgress else { return }
        lockVaultError = nil
        beginReadinessCheck(unlockReason: Self.unlockReason)
    }

    /// "Start Over with Saved Sign-ins", offered only while the vault key is
    /// missing: the service archives the saved sign-ins the lost key can no
    /// longer open, creates a fresh key and unlocks it. Each account then asks
    /// to sign in again.
    public func startOverWithSavedSignIns() {
        guard vaultLaunchState == .keyMissing, !teardownInProgress, !shutdownInProgress else { return }
        vaultStartOverError = nil
        beginReadinessCheck(unlockReason: Self.unlockReason, startsOver: true)
    }

    /// Explicit Lock Vault (menu bar). Vault ruling: the vault stays
    /// unlocked for the whole login session and locks only on sign-out or
    /// session end, on this explicit lock, or when the service terminates;
    /// never on window close, sleep or screen lock. The runtime stops, and
    /// resumes after an unlock from the menu bar, a window or the CLI.
    public func lockVault() async {
        guard hasStarted, !shutdownInProgress, !teardownInProgress else { return }
        let generation = nextLifecycleGeneration()
        readinessTask?.cancel()
        readinessTask = nil
        runtimeAccessTask?.cancel()
        runtimeAccessTask = nil
        teardownInProgress = true
        await releaseRuntime()
        guard lifecycleGeneration == generation, !shutdownInProgress else { return }
        if let explicitLockAction {
            do {
                try await explicitLockAction()
            } catch {
                guard lifecycleGeneration == generation, !shutdownInProgress else { return }
                // Never show a locked state the service did not reach:
                // report it and bring the runtime back.
                lockVaultError = Self.lockVaultFailureMessage
                teardownInProgress = false
                beginReadinessCheck(isRetry: true)
                return
            }
        } else {
            await lockVaultAction()
        }
        guard lifecycleGeneration == generation, !shutdownInProgress else { return }
        lockVaultError = nil
        vaultLaunchState = .locked
        teardownInProgress = false
        watchLockedVault(generation: generation)
    }

    public func shutdown() async {
        let generation = nextLifecycleGeneration()
        lockedVaultWatchTask?.cancel()
        lockedVaultWatchTask = nil
        unavailableServiceWatchTask?.cancel()
        unavailableServiceWatchTask = nil
        hasStarted = false
        shutdownInProgress = true
        teardownInProgress = true
        retryAfterTeardown = false
        readinessTask?.cancel()
        readinessTask = nil
        runtimeAccessTask?.cancel()
        runtimeAccessTask = nil
        await releaseRuntime()
        guard lifecycleGeneration == generation else { return }
        await lockVaultAction()
        guard lifecycleGeneration == generation else { return }
        vaultLaunchState = .locked
        teardownInProgress = false
        shutdownInProgress = false
    }

    public func requestNotificationOpen(token: String) {
        pendingNotificationOpenToken = token
        notificationOpenTask?.cancel()
        notificationOpenTask = nil
        resolvePendingNotificationOpenIfPossible()
    }

    public func consumeNotificationOpenRequest(id: UUID) {
        guard notificationOpenRequest?.id == id else { return }
        notificationOpenRequest = nil
    }

    /// Stops every runtime before deleting local Plainpost-managed account
    /// state through the service-owned transactional deletion path. Provider
    /// accounts and provider-hosted mail are never modified by this operation.
    public func purgePlainpostManagedData() async throws -> Data {
        let generation = nextLifecycleGeneration()
        hasStarted = false
        shutdownInProgress = true
        teardownInProgress = true
        retryAfterTeardown = false
        readinessTask?.cancel()
        readinessTask = nil
        runtimeAccessTask?.cancel()
        runtimeAccessTask = nil
        await releaseRuntime()
        guard lifecycleGeneration == generation else { throw CancellationError() }
        do {
            let digest = try await purgeManagedDataAction()
            guard digest.count == 32, !digest.allSatisfy({ $0 == 0 }) else {
                throw PlainpostError.validationFailed("Managed account purge did not produce a receipt.")
            }
            await lockVaultAction()
            guard lifecycleGeneration == generation else { throw CancellationError() }
            vaultLaunchState = .locked
            teardownInProgress = false
            shutdownInProgress = false
            return digest
        } catch {
            teardownInProgress = false
            shutdownInProgress = false
            throw error
        }
    }

    private func beginReadinessCheck(
        unlockReason: String? = nil,
        startsOver: Bool = false,
        isRetry: Bool = false
    ) {
        guard !shutdownInProgress else { return }
        if teardownInProgress {
            if isRetry {
                retryAfterTeardown = true
            }
            return
        }
        let generation = nextLifecycleGeneration()
        readinessTask?.cancel()
        lockedVaultWatchTask?.cancel()
        lockedVaultWatchTask = nil
        vaultLaunchState = .checking
        readinessTask = Task { [prepareServiceAction, vaultReadiness, unlockVaultAction, startOverVaultAction] in
            await prepareServiceAction()
            guard !Task.isCancelled else { return }
            let initialState =
                if let unlockReason {
                    startsOver
                        ? await startOverVaultAction(unlockReason)
                        : await unlockVaultAction(unlockReason)
                } else {
                    await vaultReadiness()
                }
            #if DEBUG
            let state =
                if unlockReason == nil, let acceptanceReadinessBootstrap {
                    await acceptanceReadinessBootstrap(initialState)
                } else { initialState }
            #else
            let state = initialState
            #endif
            guard !Task.isCancelled else { return }
            await applyVaultLaunchState(state, isRetry: isRetry, generation: generation)
            if startsOver, lifecycleGeneration == generation {
                switch state {
                case .ready: startedOverWithSavedSignIns = true
                case .keyMissing: vaultStartOverError = Self.vaultStartOverFailureMessage
                default: break
                }
            }
        }
    }

    private func applyVaultLaunchState(
        _ state: PlainpostVaultLaunchState,
        isRetry: Bool,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation, !shutdownInProgress else { return }
        guard state == .ready else {
            teardownInProgress = true
            await releaseRuntime()
            guard lifecycleGeneration == generation, !shutdownInProgress else { return }
            enterNonReadyState(state, generation: generation)
            return
        }
        serviceUnavailableAttempts = 0
        vaultLaunchState = .ready
        if runtime == nil {
            initializeRuntime(isRetry: isRetry)
        }
    }

    /// Re-reads a locked vault (status only, never an unlock prompt) until
    /// it opens elsewhere, then resumes the runtime. A hidden login launch
    /// meets a locked vault after every reboot or logout; the menu bar
    /// offers the unlock, and this picks up an unlock made from the CLI.
    private func watchLockedVault(generation: UInt64) {
        lockedVaultWatchTask?.cancel()
        let interval = lockedVaultPollInterval
        lockedVaultWatchTask = Task { [weak self, vaultReadiness] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.lifecycleGeneration == generation,
                      self.vaultLaunchState == .locked,
                      !self.teardownInProgress, !self.shutdownInProgress
                else { return }
                let state = await vaultReadiness()
                guard !Task.isCancelled, self.lifecycleGeneration == generation,
                      self.vaultLaunchState == .locked
                else { return }
                if state == .ready {
                    self.lockedVaultWatchTask = nil
                    await self.applyVaultLaunchState(.ready, isRetry: true, generation: generation)
                    return
                }
            }
        }
    }

    private func releaseRuntime() async {
        notificationOpenTask?.cancel()
        notificationOpenTask = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        if let runtimeShutdownTask {
            await runtimeShutdownTask.value
            return
        }
        guard let runtimeToShutdown = runtime else { return }
        runtime = nil
        runtimeReadOnly = nil
        let shutdownRuntime = shutdownRuntime
        let task = Task { @MainActor in
            await shutdownRuntime(runtimeToShutdown)
        }
        runtimeShutdownTask = task
        await task.value
        runtimeShutdownTask = nil
    }

    private func handleRuntimeFailure(
        _ error: PlainpostServiceClientError,
        from failedRuntime: PlainpostAppRuntime
    ) async {
        guard runtime === failedRuntime,
            let state = PlainpostVaultReadinessGate.runtimeFailureState(for: error)
        else { return }
        let generation = nextLifecycleGeneration()
        readinessTask?.cancel()
        readinessTask = nil
        teardownInProgress = true
        vaultLaunchState = .checking
        await releaseRuntime()
        guard lifecycleGeneration == generation, !shutdownInProgress else { return }
        if error == .serviceUnavailable || error == .timedOut {
            teardownInProgress = false
            retryAfterTeardown = false
            beginReadinessCheck(isRetry: true)
            return
        }
        // A CLI lock surfaces here as a runtime failure; the watch started
        // below lets a later CLI unlock resume the runtime.
        enterNonReadyState(state, generation: generation)
    }

    /// Publishes a state other than ready and keeps it recovering without a
    /// window: a locked vault is re-read, an unavailable service is asked
    /// again on a backoff. A retry queued during teardown runs instead.
    private func enterNonReadyState(_ state: PlainpostVaultLaunchState, generation: UInt64) {
        vaultLaunchState = state
        if state == .locked { lockVaultError = nil }
        let retryQueued = retryAfterTeardown
        finishTeardown(generation: generation)
        guard !retryQueued, lifecycleGeneration == generation, !shutdownInProgress else { return }
        switch state {
        case .locked: watchLockedVault(generation: generation)
        case .serviceUnavailable: watchUnavailableService(generation: generation)
        default: break
        }
    }

    /// Re-runs readiness for an unavailable service (busy migrating, hung,
    /// or not loaded yet) on a bounded backoff, capped at five minutes. Each
    /// pass goes through `prepareService`, which restarts a service that
    /// stays busy too long.
    private func watchUnavailableService(generation: UInt64) {
        unavailableServiceWatchTask?.cancel()
        let delay = serviceUnavailableBackoff[min(serviceUnavailableAttempts, serviceUnavailableBackoff.count - 1)]
        serviceUnavailableAttempts += 1
        unavailableServiceWatchTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.lifecycleGeneration == generation,
                  self.vaultLaunchState == .serviceUnavailable,
                  !self.teardownInProgress, !self.shutdownInProgress
            else { return }
            self.unavailableServiceWatchTask = nil
            self.beginReadinessCheck(isRetry: true)
        }
    }

    private func initializeRuntime(isRetry: Bool = false) {
        guard runtime == nil, runtimeShutdownTask == nil, !teardownInProgress, !shutdownInProgress
        else { return }
        monitoringTask?.cancel()
        monitoringTask = nil

        do {
            let runtime = try (accountReadOnly ? makeReadOnlyRuntime : makeRuntime)()
            self.runtime = runtime
            runtimeReadOnly = accountReadOnly
            runtimeError = nil
            resolvePendingNotificationOpenIfPossible()
            reconcileMailMonitoring()
        } catch {
            runtime = nil
#if DEBUG
            if acceptanceReadinessBootstrap != nil {
                FileHandle.standardError.write(
                    Data("Plainpost acceptance: runtime initialization unavailable\n".utf8)
                )
            }
#endif
            runtimeError = isRetry
                ? "Local runtime initialization still failed. Check that the local data directory is writable, then try again."
                : "Local runtime initialization failed. Check that the local data directory is writable, then try again."
        }
    }

    private func reconcileMailMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        guard !accountReadOnly, let runtime else { return }
        let monitor = monitor
        monitoringTask = Task { [weak self, runtime, monitor] in
            do {
                await runtime.startNewMailAlerts()
                guard !Task.isCancelled else { return }
                try await monitor(runtime)
            } catch is CancellationError {
                return
            } catch let error as PlainpostServiceClientError {
                guard !Task.isCancelled else { return }
                await self?.handleRuntimeFailure(error, from: runtime)
            } catch {
                return
            }
        }
    }

    private func resolvePendingNotificationOpenIfPossible() {
        guard notificationOpenTask == nil,
              let token = pendingNotificationOpenToken,
              let runtime
        else { return }
        notificationOpenTask = Task { [weak self, runtime] in
            let destination = await runtime.resolveNotificationOpen(token)
            guard !Task.isCancelled, let self,
                  self.runtime === runtime,
                  self.pendingNotificationOpenToken == token
            else { return }
            self.pendingNotificationOpenToken = nil
            self.notificationOpenRequest = PlainpostNotificationOpenRequest(
                destination: destination
            )
            self.notificationOpenTask = nil
        }
    }

    private func replaceRuntimeForAccountAccess() {
        let generation = nextLifecycleGeneration()
        runtimeAccessTask?.cancel()
        teardownInProgress = true
        runtimeAccessTask = Task { [weak self] in
            guard let self else { return }
            await self.releaseRuntime()
            guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
            self.teardownInProgress = false
            self.runtimeAccessTask = nil
            self.initializeRuntime()
        }
    }

    private func nextLifecycleGeneration() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func finishTeardown(generation: UInt64) {
        guard lifecycleGeneration == generation, !shutdownInProgress else { return }
        teardownInProgress = false
        guard retryAfterTeardown else { return }
        retryAfterTeardown = false
        beginReadinessCheck(isRetry: true)
    }
}

/// Hands the service ownership found by the restorer (off the main actor)
/// to the application model.
final class PlainpostServiceOwnershipRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@MainActor (PlainpostServiceOwnership) -> Void)?

    var handler: (@MainActor (PlainpostServiceOwnership) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    func publish(_ ownership: PlainpostServiceOwnership) {
        let handler = handler
        Task { @MainActor in handler?(ownership) }
    }
}

/// What the bundled-service restorer does on each readiness check.
enum PlainpostBundledServiceRestore {
    /// Asks the running service who it is. Unreachable means the job is
    /// missing or unloaded.
    static func reported(
        _ client: any PlainpostServiceClientProtocol
    ) async -> PlainpostBundledServiceRefreshPolicy.Reported {
        // A timeout means the job answered the lookup but is still busy
        // starting; ask once more before calling it busy.
        for attempt in 1...2 {
            do {
                guard let identity = try await client.serviceIdentity() else { return .unidentified }
                return .identity(identity)
            } catch PlainpostServiceClientError.timedOut {
                if attempt == 2 { return .busy }
            } catch {
                return .unreachable
            }
        }
        return .busy
    }

    /// Bounces the service only when the policy says so, then reports who
    /// runs it.
    static func run(
        client: any PlainpostServiceClientProtocol,
        expected: PlainpostServiceBuildIdentity?,
        isRegistered: Bool,
        unregister: () async throws -> Void,
        register: () async throws -> Void,
        publish: (PlainpostServiceOwnership) -> Void,
        busyTracker: PlainpostServiceBusyTracker = PlainpostServiceBusyTracker(),
        now: Date = Date(),
        bundleIsGone: (String) -> Bool = { PlainpostBundlePresence.isGone(path: $0) }
    ) async throws {
        let firstAnswer = await reported(client)
        let busy = busyTracker.record(firstAnswer, now: now)
        let decision = PlainpostBundledServiceRefreshPolicy.decide(
            isRegistered: isRegistered,
            reported: firstAnswer,
            expected: expected,
            consecutiveBusyChecks: busy.count,
            busyDuration: busy.duration,
            bundleIsGone: bundleIsGone
        )
        switch decision {
        case .keepRunning:
            publish(firstAnswer == .busy ? .unknown : .own)
        case .foreign(let bundlePath):
            publish(.foreign(bundlePath: bundlePath))
        case .refresh:
            busyTracker.reset()
            try await PlainpostBundledAgentRefresh.refresh(
                isEnabled: isRegistered,
                unregister: unregister,
                register: register
            )
            if case .identity(let identity) = await reported(client) {
                publish(PlainpostServiceOwnership.evaluate(reported: identity, expected: expected))
            } else {
                publish(.unknown)
            }
        }
    }
}

@MainActor
final class DefaultGUIServiceOwner {
    private let configuration: PlainpostAppRuntimeConfiguration
    private let serviceClient: any PlainpostServiceClientProtocol
    private let readinessGate: PlainpostVaultReadinessGate
    private let serviceRestorer: PlainpostPackagedServiceRestorer
    let ownershipRelay = PlainpostServiceOwnershipRelay()
    private let busyTracker = PlainpostServiceBusyTracker()

    init(
        configuration: PlainpostAppRuntimeConfiguration,
        serviceClient: (any PlainpostServiceClientProtocol)? = nil
    ) {
        self.configuration = configuration
        let resolved = serviceClient ?? configuration.serviceClient
        self.serviceClient = resolved
        readinessGate = PlainpostVaultReadinessGate(serviceClient: resolved)
        #if os(macOS)
        let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(PlainpostPackagedServiceRestorer.bundledPlistName)
        let relay = ownershipRelay
        let busyTracker = busyTracker
        let appBundleURL = Bundle.main.bundleURL
        serviceRestorer = PlainpostPackagedServiceRestorer(
            appBundleURL: appBundleURL,
            legacyPlistURL: legacyPlistURL,
            registerService: {
                let service = SMAppService.agent(
                    plistName: PlainpostPackagedServiceRestorer.bundledPlistName
                )
                try await PlainpostBundledServiceRestore.run(
                    client: resolved,
                    expected: PlainpostServiceBuildIdentity.bundledService(appBundleURL: appBundleURL),
                    isRegistered: service.status == .enabled,
                    unregister: { try await service.unregister() },
                    register: { try service.register() },
                    publish: { relay.publish($0) },
                    busyTracker: busyTracker
                )
            }
        )
        #else
        // iOS has no launchd background agent to restore; use a no-op restorer
        // with the same call surface as the macOS one.
        serviceRestorer = PlainpostPackagedServiceRestorer(
            appBundleURL: Bundle.main.bundleURL,
            legacyPlistURL: nil,
            registerService: {}
        )
        #endif
    }

    func makeRuntime(accountAccess: PlainpostRuntimeAccountAccess = .readWrite) throws -> PlainpostAppRuntime {
        try PlainpostAppRuntime(configuration: configuration, accountAccess: accountAccess)
    }

    func prepareService() async {
        do {
            _ = try await serviceRestorer.restore()
        } catch {
            let nsError = error as NSError
            packagedServiceLogger.error(
                "restore_failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
            )
        }
    }

    func evaluate() async -> PlainpostVaultLaunchState { await readinessGate.evaluate() }

    func unlock(reason: String) async -> PlainpostVaultLaunchState {
        await readinessGate.unlock(reason: reason)
    }

    func startOver(reason: String) async -> PlainpostVaultLaunchState {
        await readinessGate.startOver(reason: reason)
    }

    func lock() async { try? await serviceClient.lock() }

    func lockReportingFailure() async throws { try await serviceClient.lock() }

    func purgeManagedData() async throws -> Data {
        let accountIDs = try localAccountIDs()
        let delete = plainpostServiceAccountDeleter(serviceClient: serviceClient)
        for accountID in accountIDs {
            try await delete(accountID)
        }
        guard try localAccountIDs().isEmpty else {
            throw PlainpostError.validationFailed("Plainpost-managed account data remains after purge.")
        }
        try CalendarSnapshotCache.clearAll(appDataRoot: configuration.databaseURL.deletingLastPathComponent())
        var receipt = Data("Plainpost.ManagedAccountPurge.v1".utf8)
        for accountID in accountIDs {
            let value = Data(accountID.rawValue.utf8)
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { receipt.append(contentsOf: $0) }
            receipt.append(value)
        }
        return Data(SHA256.hash(data: receipt))
    }

    private func localAccountIDs() throws -> [AccountID] {
        guard FileManager.default.fileExists(atPath: configuration.databaseURL.path) else { return [] }
        let store = try SQLiteMailStore(path: configuration.databaseURL.path, readOnly: true)
        return store.accounts.map(\.id).sorted { $0.rawValue < $1.rawValue }
    }
}
