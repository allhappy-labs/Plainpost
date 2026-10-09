@preconcurrency import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime

protocol ServiceMailMonitoring: Sendable {
    func start() async
    func stop() async
}

protocol IMAPIdleSupervising: Sendable {
    func reconcileAccounts() async
    func stop() async
}

extension IMAPIdleSupervisor: IMAPIdleSupervising {}

actor ServiceMailMonitor: ServiceMailMonitoring {
    static let fallbackInterval: Duration = .seconds(5 * 60)

    private enum State {
        case inactive
        case running
        case stopped
    }

    private let store: SQLiteMailStore
    private let idleSupervisor: any IMAPIdleSupervising
    private let signal: IMAPIdleSupervisor.Signal
    private let sleep: @Sendable (Duration) async throws -> Void
    private let notificationCenter: NotificationCenter
    private let observeDistributedNotifications: Bool
    private var state = State.inactive
    private var fallbackTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var accountChangeTask: Task<Void, Never>?
    private var accountChangePending = false
    private var shutdownTask: Task<Void, Never>?
    private var localObserver: NSObjectProtocol?
#if os(macOS)
    private var distributedObserver: NSObjectProtocol?
#endif

    init(
        store: SQLiteMailStore,
        idleSupervisor: any IMAPIdleSupervising,
        signal: @escaping IMAPIdleSupervisor.Signal,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        notificationCenter: NotificationCenter = .default,
        observeDistributedNotifications: Bool = true
    ) {
        self.store = store
        self.idleSupervisor = idleSupervisor
        self.signal = signal
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        self.observeDistributedNotifications = observeDistributedNotifications
    }

    func start() async {
        guard state == .inactive else { return }
        state = .running
        installObservers()
        let startup = Task { [idleSupervisor] in
            await idleSupervisor.reconcileAccounts()
        }
        startupTask = startup
        await startup.value
        startupTask = nil
        guard state == .running else { return }
        fallbackTask = Task { [weak self] in
            await self?.runFallbackLoop()
        }
    }

    func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard state == .running else { return }
        state = .stopped
        removeObservers()
        accountChangePending = false
        let startup = startupTask
        let fallback = fallbackTask
        let accountChange = accountChangeTask
        fallbackTask = nil
        fallback?.cancel()
        // Retain the same join for every stop caller. Admitted signals may
        // own durable work, so let them settle before stopping the supervisor.
        let shutdown = Task { [idleSupervisor] in
            await startup?.value
            await fallback?.value
            await accountChange?.value
            await idleSupervisor.stop()
        }
        shutdownTask = shutdown
        await shutdown.value
    }

    private func installObservers() {
        localObserver = notificationCenter.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            guard scope == .accounts || scope == .all else { return }
            Task { await self?.accountsDidChange() }
        }
#if os(macOS)
        if observeDistributedNotifications {
            distributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: MailStoreChangeSignal.notificationName,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let scope = MailStoreChangeSignal.scope(from: notification)
                guard scope == .accounts || scope == .all else { return }
                Task { await self?.accountsDidChange() }
            }
        }
#endif
    }

    private func removeObservers() {
        if let localObserver {
            notificationCenter.removeObserver(localObserver)
            self.localObserver = nil
        }
#if os(macOS)
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(
                distributedObserver
            )
            self.distributedObserver = nil
        }
#endif
    }

    private func accountsDidChange() {
        guard state == .running else { return }
        accountChangePending = true
        guard accountChangeTask == nil else { return }
        accountChangeTask = Task { [weak self] in
            await self?.reconcileAccountChanges()
        }
    }

    private func reconcileAccountChanges() async {
        defer { accountChangeTask = nil }
        await startupTask?.value
        while state == .running && accountChangePending {
            accountChangePending = false
            await idleSupervisor.reconcileAccounts()
            guard state == .running else { return }
            await signalEnabledAccounts()
            // Any notification admitted across either await requests one fresh
            // pass, including a fresh enabled-account snapshot.
        }
    }

    private func runFallbackLoop() async {
        await signalEnabledAccounts()
        while state == .running && !Task.isCancelled {
            do {
                try await sleep(Self.fallbackInterval)
            } catch {
                return
            }
            guard state == .running, !Task.isCancelled else { return }
            // Rebuilds watchers a reconcile dropped while the account sources
            // were unreadable; no `.accounts` change will come to do it.
            await idleSupervisor.reconcileAccounts()
            guard state == .running, !Task.isCancelled else { return }
            await signalEnabledAccounts()
        }
    }

    private func signalEnabledAccounts() async {
        let enabledAccountIDs = store.directSyncAccounts.compactMap { account in
            let enabled =
                (try? store.syncPreferences(accountID: account.id)
                    .realTimeMonitoringEnabled) == true
            return enabled ? account.id : nil
        }
        for accountID in enabledAccountIDs where state == .running {
            try? await signal(accountID)
        }
    }
}
