@preconcurrency import Foundation
import PlainpostDB

@MainActor
final class MailStoreChangeMonitor: ObservableObject {
    @Published private(set) var mailboxRevision: UInt64 = 0
    @Published private(set) var accountRevision: UInt64 = 0
    @Published private(set) var operationRevision: UInt64 = 0

    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var mailboxDebounceTask: Task<Void, Never>?
    private var accountDebounceTask: Task<Void, Never>?
    private var operationDebounceTask: Task<Void, Never>?

    /// The single store-change observer of a Plainpost surface. Both centers
    /// `MailStoreChangeSignal.post` writes to are observed, so an in-process
    /// signal arrives twice; the debounce collapses the pair into one
    /// revision, and every reader must go through this monitor rather than
    /// add an observer of its own.
    ///
    /// `distributedNotificationCenter` is the cross-process center; tests pass
    /// a private stand-in so they never broadcast to the whole machine, and
    /// `observeDistributedNotifications: false` drops that half entirely.
    init(
        notificationCenter: NotificationCenter = .default,
        observeDistributedNotifications: Bool = true,
        distributedNotificationCenter: NotificationCenter? = nil
    ) {
        observe(notificationCenter)
        guard observeDistributedNotifications else { return }
        if let distributedNotificationCenter {
            observe(distributedNotificationCenter)
            return
        }
#if os(macOS)
        observe(DistributedNotificationCenter.default())
#endif
    }

    private func observe(_ center: NotificationCenter) {
        let token = center.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            Task { @MainActor in self?.receiveChange(scope) }
        }
        observations.append((center, token))
    }

    deinit {
        mailboxDebounceTask?.cancel()
        accountDebounceTask?.cancel()
        operationDebounceTask?.cancel()
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
    }

    private func receiveChange(_ scope: MailStoreChangeScope) {
        switch scope {
        case .mailbox:
            debounceMailbox()
        case .accounts:
            debounceAccounts()
        case .operations:
            debounceOperations()
        case .all:
            debounceMailbox()
            debounceAccounts()
            debounceOperations()
        }
    }

    private func debounceMailbox() {
        // Import can commit faster than the debounce interval indefinitely.
        // Keep one fixed window so active imports publish while they run;
        // its snapshot read includes every commit coalesced into this window.
        guard mailboxDebounceTask == nil else { return }
        mailboxDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.mailboxDebounceTask = nil
            self?.mailboxRevision &+= 1
        }
    }

    private func debounceAccounts() {
        accountDebounceTask?.cancel()
        accountDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.accountRevision &+= 1
        }
    }

    private func debounceOperations() {
        operationDebounceTask?.cancel()
        operationDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.operationRevision &+= 1
        }
    }
}
