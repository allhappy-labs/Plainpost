import Combine
import Foundation

/// One piece of background mail work a surface lists: Smart Inbox sorting, a sync in
/// progress, or a sync that failed.
struct MailActivity: Equatable, Identifiable {
    enum Kind: Equatable { case smartInbox, sync, syncFailure }
    let id: String
    let kind: Kind
    /// "Sorting Smart Inbox", "Syncing mail", "Couldn't sync".
    let title: String
    /// "1,995 left", or the failure's text.
    let detail: String?
    let fraction: Double?
    /// Shows Retry, which calls `retrySync()`.
    let retry: Bool
}

extension MailActivity {
    static let hostSyncFailureID = "host-sync-failure"

    /// The Activity row's one line: "Sorting Smart Inbox · 1,995 left",
    /// "Syncing me@example.com · INBOX · 10 of 40", "Couldn't sync".
    var line: String {
        detail.map { "\(title) · \($0)" } ?? title
    }

    /// What a mailbox list's failure line says: the failure's own message, else the title.
    var failureMessage: String {
        detail ?? title
    }

    /// The host app's own sync of one account (the iPhone's Direct sync).
    static func hostSync(accountTitle: String, detail: String?, fraction: Double?) -> MailActivity {
        MailActivity(id: "host-sync", kind: .sync, title: "Syncing \(accountTitle)",
                     detail: detail, fraction: fraction, retry: false)
    }

    static func hostSyncFailure(accountTitle: String, message: String) -> MailActivity {
        MailActivity(id: hostSyncFailureID, kind: .syncFailure, title: "Couldn't sync \(accountTitle)",
                     detail: message, fraction: nil, retry: true)
    }

    /// The Retry button's accessibility identifier in `list`: the first retryable row keeps
    /// the plain `mailboxes.activity.retry`; any other adds its id, so two failures shown
    /// together never share one.
    func retryAccessibilityIdentifier(in list: [MailActivity]) -> String {
        list.first(where: \.retry)?.id == id ? "mailboxes.activity.retry" : "mailboxes.activity.retry.\(id)"
    }
}

/// Keeps a mail surface current while it's on screen: the refresh wiring PlainpostRootView
/// used to hold in `.task` and `.onChange` modifiers, and the list of background activity.
/// A view runs `attach()` from a `.task`, so it lives exactly as long as the view.
@MainActor
final class MailActivityCoordinator: ObservableObject {
    @Published private(set) var activities: [MailActivity]
    var smartInboxEnabled = true { didSet { recomputeActivities() } }
    /// Sync work the host app runs itself (the iPhone's Direct sync), listed with this
    /// surface's own activity. Empty on macOS.
    var hostActivities: [MailActivity] = [] {
        didSet { recomputeActivities() }
    }
    /// The locale Smart Inbox activity is formatted for. Settable so a view can keep it
    /// matched to its environment.
    var locale: Locale
    /// The last step of `attach()`'s bootstrap. Settable so a view can connect it once its
    /// own state exists.
    var refreshSmartInbox: @MainActor () async -> Void
    /// Runs in the bootstrap once the approval queue has loaded, before `refreshSmartInbox`.
    var didRefreshApprovals: @MainActor () -> Void = {}
    /// Runs after each snapshot refresh, so what's derived from the same mail (the session's
    /// mailbox directory) follows it.
    var didRefreshSnapshot: @MainActor () async -> Void = {}
    /// Fences an admitted directory read as soon as its source becomes dirty.
    var didInvalidateSnapshot: @MainActor () -> Void = {}

    private var attachedWork: RefreshWork?
    /// The Mailboxes surface's own lane in the same attachment: the folder directory and the
    /// activity list. While the main worker runs a long step (the bootstrap's Smart Inbox
    /// run) a Mailboxes screen still loads its folders, and the run's progress still shows.
    private var attachedDirectoryWork: RefreshWork?
    /// True while the main worker awaits the bootstrap's Smart Inbox run, so its follow-up
    /// directory load would wait for the whole run.
    private var smartInboxRunInProgress = false
    /// True while the lane's directory load runs; a fence during it discards that load.
    private var directoryLoadInFlight = false
    private let refreshBus: MailboxRefreshBus
    private let inboxSnapshot: InboxViewModelSnapshotStore
    private let approvalQueue: ApprovalQueueViewModel
    private let nodeStatus: NodeMailModeStatusModel
    private let accountSetup: AccountSetupViewModel
    private let storeChanges: MailStoreChangeMonitor
    private let smartInbox: SmartInboxActivityCoordinator
    private let maintenance: MailMaintenanceViewModel
    private let selectedMessageID: @MainActor () -> String?
    private let invalidateSnapshot: @MainActor () -> Void
    private let refreshSearchMailboxes: @MainActor (Bool) async -> Void

    init(
        refreshBus: MailboxRefreshBus,
        inboxSnapshot: InboxViewModelSnapshotStore,
        approvalQueue: ApprovalQueueViewModel,
        nodeStatus: NodeMailModeStatusModel,
        accountSetup: AccountSetupViewModel,
        storeChanges: MailStoreChangeMonitor,
        smartInbox: SmartInboxActivityCoordinator,
        maintenance: MailMaintenanceViewModel,
        selectedMessageID: @escaping @MainActor () -> String?,
        invalidateSnapshot: @escaping @MainActor () -> Void,
        refreshSearchMailboxes: @escaping @MainActor (Bool) async -> Void,
        refreshSmartInbox: @escaping @MainActor () async -> Void,
        locale: Locale
    ) {
        self.refreshBus = refreshBus
        self.inboxSnapshot = inboxSnapshot
        self.approvalQueue = approvalQueue
        self.nodeStatus = nodeStatus
        self.accountSetup = accountSetup
        self.storeChanges = storeChanges
        self.smartInbox = smartInbox
        self.maintenance = maintenance
        self.selectedMessageID = selectedMessageID
        self.invalidateSnapshot = invalidateSnapshot
        self.refreshSearchMailboxes = refreshSearchMailboxes
        self.refreshSmartInbox = refreshSmartInbox
        self.locale = locale
        self.activities = Self.activities(
            smartInbox: smartInboxEnabled ? smartInbox.presentation : nil,
            syncState: maintenance.syncState,
            isSyncing: maintenance.isSyncing,
            locale: locale
        )
    }

    /// The calling view task owns the worker and joins every admitted dependency on
    /// cancellation. Synchronous subscriptions merge dirty domains without losing a
    /// final revision while the worker is suspended; the stream is only a bounded wakeup.
    func attach() async {
        // SwiftUI can start a replacement view task before the cancelled task has
        // joined a non-cancellable read. Its successor must wait for that join.
        while let previous = attachedWork {
            await previous.waitUntilFinished()
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        let work = RefreshWork()
        attachedWork = work
        let directoryWork = RefreshWork()
        attachedDirectoryWork = directoryWork
        var subscriptions: Set<AnyCancellable> = []
        func invalidate(_ domains: RefreshDomains) {
            // During the Smart Inbox run the mailbox is read on the lane that doesn't wait for
            // it: a fresh session whose first read was fenced by a sync import would otherwise
            // show no messages until the run ends.
            let rereadsSnapshotNow = smartInboxRunInProgress && domains.contains(.snapshot)
            guard work.enqueue(rereadsSnapshotNow ? domains.subtracting(.snapshot) : domains) else { return }
            if rereadsSnapshotNow { directoryWork.enqueue(.snapshot) }
            invalidateSnapshot()
            didInvalidateSnapshot()
            // The fence discards a directory load in flight, and the main worker's follow-up
            // load waits for its current step: the lane loads again now instead, so the
            // folder list (and its counts) never wait for a long step like the bootstrap's
            // Smart Inbox run.
            if directoryLoadInFlight || smartInboxRunInProgress { directoryWork.enqueue(.directory) }
        }
        refreshBus.$revision.dropFirst().sink { _ in
            invalidate([.search, .snapshot])
        }.store(in: &subscriptions)
        approvalQueue.$items.map { items in
            items.filter { $0.status.caseInsensitiveCompare("pending") == .orderedSame }.count
        }.removeDuplicates().dropFirst().sink { _ in
            invalidate(.snapshot)
        }.store(in: &subscriptions)
        storeChanges.$mailboxRevision.dropFirst().sink { _ in
            guard work.enqueue([]) else { return }
            self.refreshBus.bump()
        }.store(in: &subscriptions)
        storeChanges.$accountRevision.dropFirst().sink { _ in
            guard work.enqueue([.accounts, .nodeStatus]) else { return }
            self.refreshBus.bump()
        }.store(in: &subscriptions)
        storeChanges.$operationRevision.dropFirst().sink { _ in
            directoryWork.enqueue(.activity)
            work.enqueue([.approvals, .syncStatuses])
        }.store(in: &subscriptions)
        maintenance.$successRevision.dropFirst().sink { _ in
            guard directoryWork.enqueue(.activity) else { return }
            self.refreshBus.bump()
        }.store(in: &subscriptions)

        work.enqueue([.bootstrap, .activity, .snapshot, .approvals, .nodeStatus])
        defer {
            subscriptions.forEach { $0.cancel() }
            work.continuation.finish()
            directoryWork.continuation.finish()
            if attachedDirectoryWork === directoryWork { attachedDirectoryWork = nil }
            if attachedWork === work { attachedWork = nil }
            directoryWork.finish()
            work.finish()
        }
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                group.addTask { await self.runRefreshes(work) }
                group.addTask { await self.runDirectoryRefreshes(directoryWork) }
                group.addTask { await self.pollNodeStatus(work) }
                group.addTask { await self.observeActivities() }
            }
        } onCancel: {
            // Also closes admission from synchronous Combine callbacks while an
            // already admitted, non-cancellable dependency is still being joined.
            work.continuation.finish()
            directoryWork.continuation.finish()
        }
    }

    /// Visibility is only an invalidation; attach remains the lifetime owner of reads.
    func requestDirectoryRefresh() {
        attachedDirectoryWork?.enqueue(.directory)
    }

    /// Account metadata changes share the attach-owned worker with store revisions.
    /// A detached host cannot start reads, and bursts merge while an admitted read runs.
    func requestSearchMailboxRefresh() {
        attachedWork?.enqueue(.search)
    }

    func retrySync() async {
        await maintenance.syncNow()
    }

    /// The activity list, most urgent first: failed syncs (the host's, then this surface's),
    /// syncs in progress (likewise), then Smart Inbox. Counts are formatted for `locale`.
    static func activities(
        smartInbox: SmartInboxActivityPresentation?,
        syncState: MailMaintenanceActionState,
        isSyncing: Bool,
        host: [MailActivity] = [],
        locale: Locale = .current
    ) -> [MailActivity] {
        var activities = host.filter { $0.kind == .syncFailure }
        if case let .failure(message) = syncState {
            activities.append(MailActivity(
                id: "sync-failure", kind: .syncFailure, title: "Couldn't sync",
                detail: message, fraction: nil, retry: true
            ))
        }
        activities += host.filter { $0.kind == .sync }
        if isSyncing {
            activities.append(MailActivity(
                id: "sync", kind: .sync, title: "Syncing mail",
                detail: nil, fraction: nil, retry: false
            ))
        }
        if let smartInbox {
            activities.append(MailActivity(
                id: smartInbox.id,
                kind: .smartInbox,
                title: smartInbox.title,
                detail: smartInbox.remaining.map { "\($0.formatted(.number.locale(locale))) left" }
                    ?? smartInbox.compactDetail,
                fraction: smartInbox.fraction,
                retry: false
            ))
        }
        return activities
    }

    /// A finished sync or Smart Inbox rerun: the mailbox moves on and the activity reloads.
    static func applyMailMaintenanceSuccess(
        advanceMailbox: () -> Void,
        refreshActivity: () -> Void
    ) {
        MailMaintenanceSuccessPolicy.perform(
            advanceMailbox: advanceMailbox,
            refreshActivity: refreshActivity
        )
    }

    // MARK: - Wiring

    private struct RefreshDomains: OptionSet {
        let rawValue: Int
        static let snapshot = Self(rawValue: 1 << 0)
        static let search = Self(rawValue: 1 << 1)
        static let approvals = Self(rawValue: 1 << 2)
        static let accounts = Self(rawValue: 1 << 3)
        static let syncStatuses = Self(rawValue: 1 << 4)
        static let nodeStatus = Self(rawValue: 1 << 5)
        static let activity = Self(rawValue: 1 << 6)
        static let bootstrap = Self(rawValue: 1 << 7)
        static let directory = Self(rawValue: 1 << 8)
    }

    /// Scoped to one attach call; there is one active set and one merged pending set.
    @MainActor
    private final class RefreshWork {
        let stream: AsyncStream<Void>
        nonisolated let continuation: AsyncStream<Void>.Continuation
        private var pending: RefreshDomains = []
        private var finished = false
        private var finishWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

        init() {
            (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        @discardableResult
        func enqueue(_ domains: RefreshDomains) -> Bool {
            if case .terminated = continuation.yield(()) { return false }
            pending.formUnion(domains)
            return true
        }

        /// Takes `domains` out of the pending set; true when they were all pending.
        func removePending(_ domains: RefreshDomains) -> Bool {
            defer { pending.subtract(domains) }
            return pending.isSuperset(of: domains)
        }

        func takePending() -> RefreshDomains {
            defer { pending = [] }
            return pending
        }

        func waitUntilFinished() async {
            guard !finished, !Task.isCancelled else { return }
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            finishWaiters[id] = continuation
            defer { finishWaiters[id] = nil }
            // AsyncStream resumes a cancelled waiter without cancelling the owner.
            for await _ in stream { }
        }

        func finish() {
            finished = true
            finishWaiters.values.forEach { $0.finish() }
            finishWaiters.removeAll()
        }
    }

    private func runRefreshes(_ work: RefreshWork) async {
        for await _ in work.stream {
            guard !Task.isCancelled else { return }
            let domains = work.takePending()
            guard !domains.isEmpty else { continue }
            await refresh(domains, work: work)
        }
    }

    /// Activity reads and directory loads, merged while one runs. They never wait for the
    /// main worker's current step; the directory keeps the newest of overlapping loads.
    private func runDirectoryRefreshes(_ work: RefreshWork) async {
        for await _ in work.stream {
            guard !Task.isCancelled else { return }
            let domains = work.takePending()
            if domains.contains(.activity) { smartInbox.refresh(locale: locale) }
            if domains.contains(.snapshot) { await refreshSnapshot(requeueingOn: work) }
            // The directory follows a snapshot here too.
            if !domains.isDisjoint(with: [.snapshot, .directory]) {
                directoryLoadInFlight = true
                await didRefreshSnapshot()
                directoryLoadInFlight = false
            }
        }
    }

    private func pollNodeStatus(_ work: RefreshWork) async {
        // Bootstrap includes the initial read. Later polls enter the same worker.
        while !Task.isCancelled {
            do { try await Task.sleep(for: NodeMailModeStatusModel.pollInterval) }
            catch { return }
            work.enqueue(.nodeStatus)
        }
    }

    private func refresh(_ domains: RefreshDomains, work: RefreshWork) async {
        guard !Task.isCancelled else { return }
        if domains.contains(.activity) { smartInbox.refresh(locale: locale) }
        if domains.contains(.accounts) { accountSetup.applyAccountStoreChange() }
        if domains.contains(.search) {
            await refreshSearchMailboxes(true)
            guard !Task.isCancelled else { return }
        }
        if domains.contains(.snapshot) {
            await refreshSnapshot(requeueingOn: work)
            guard !Task.isCancelled else { return }
        }
        // The directory follows the snapshot without holding up bootstrap approvals.
        // This child is joined even when its loader does not support cancellation.
        async let directory: Void = refreshDirectory(if: !domains.intersection([.snapshot, .directory]).isEmpty)
        if domains.contains(.approvals), !Task.isCancelled {
            try? await approvalQueue.refresh()
        }
        guard !Task.isCancelled else { return }
        if domains.contains(.syncStatuses) { accountSetup.refreshMailboxSyncStatuses() }
        if domains.contains(.bootstrap) {
            didRefreshApprovals()
            smartInboxRunInProgress = true
            // A mail change during this pass already asked for another mailbox read; it
            // must not wait for the run either.
            if work.removePending(.snapshot) { attachedDirectoryWork?.enqueue(.snapshot) }
            await refreshSmartInbox()
            smartInboxRunInProgress = false
        }
        guard !Task.isCancelled else { return }
        if domains.contains(.nodeStatus) {
            let generation = storeChanges.accountRevision
            await nodeStatus.refresh(canPublish: { self.storeChanges.accountRevision == generation })
        }
        await directory
    }

    /// Publishes a fresh mailbox unless the selection, accounts, mail or approvals changed
    /// while it was read; a changed selection is read again on `work`.
    private func refreshSnapshot(requeueingOn work: RefreshWork) async {
        let selection = selectedMessageID()
        let accountGeneration = storeChanges.accountRevision
        let revision = refreshBus.revision
        let pendingApprovals = approvalQueue.pendingItemCount
        await inboxSnapshot.refresh(selectedMessageID: selection, canPublish: {
            self.selectedMessageID() == selection
                && self.storeChanges.accountRevision == accountGeneration
                && self.refreshBus.revision == revision
                && self.approvalQueue.pendingItemCount == pendingApprovals
        })
        guard !Task.isCancelled else { return }
        // Selection can change without a bus revision while the provider is
        // suspended. Source/approval changes already merged their dirty scopes.
        if selectedMessageID() != selection { work.enqueue(.snapshot) }
    }

    private func refreshDirectory(if requested: Bool) async {
        guard requested, !Task.isCancelled else { return }
        await didRefreshSnapshot()
    }

    /// Recomputes `activities` from the current state whenever Smart Inbox or sync changes.
    private func observeActivities() async {
        let changes = Publishers.CombineLatest3(
            smartInbox.$presentation.map { @Sendable _ in () },
            maintenance.syncCoordinator.$state.map { @Sendable _ in () },
            maintenance.accountSetup.$isSyncing.map { @Sendable _ in () }
        )
        for await _ in changes.values {
            guard !Task.isCancelled else { return }
            recomputeActivities()
        }
    }

    private func recomputeActivities() {
        let current = Self.activities(
            smartInbox: smartInboxEnabled ? smartInbox.presentation : nil,
            syncState: maintenance.syncState,
            isSyncing: maintenance.isSyncing,
            host: hostActivities,
            locale: locale
        )
        if current != activities { activities = current }
    }
}
