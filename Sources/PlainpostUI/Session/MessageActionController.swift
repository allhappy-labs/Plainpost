import Foundation

/// The optimistic row overlays the inbox projection reads. `revision` changes on every
/// replacement so the projector can tell a new overlay set from an unchanged one.
final class MailboxOverlayProjectionState: ObservableObject {
    @Published var overlays: [String: OptimisticMailboxOverlay] = [:]
    @Published private(set) var revision: UInt64 = 0

    func replaceOverlays(with overlays: [String: OptimisticMailboxOverlay]) {
        self.overlays = overlays
        revision &+= 1
    }
}

/// Runs mailbox actions (archive, delete, read state) optimistically, independent of any
/// platform UI: it hides or restyles the row at once, leaves the reader when its message
/// goes away, and settles when the backend answers. With a non-zero `commitDelay`, mailbox
/// archive/delete wait out a grace period first and can be undone during it. macOS passes
/// `.zero`, which commits immediately.
@MainActor
final class MessageActionController: ObservableObject {
    /// Where a mailbox action came from. Ask Mail batches touch many messages: they leave an
    /// unrelated selection alone, and refresh and report failures once per batch
    /// (`askMailActionsSettled`) instead of once per message.
    enum Origin { case mailbox, askMailBatch }

    /// The archive or delete that `undo()` would cancel.
    struct PendingUndo: Equatable, Identifiable {
        let id: UUID
        let messageID: String
        let action: InboxMailAction
    }

    @Published private(set) var pendingUndo: PendingUndo?
    let overlayState: MailboxOverlayProjectionState
    let mutations: OptimisticMutationCoordinator<String>
    /// Reprojects the inbox after an overlay change. Settable so a view can connect it once
    /// its own state exists.
    var reproject: @MainActor () -> Void
    /// Shows a mailbox action's failure. Settable for the same reason as `reproject`.
    var reportFailure: @MainActor (String) -> Void
    /// Runs when an action has reached the backend, before its overlay clears; never for an
    /// undone, superseded or rolled-back one. A list that isn't the inbox projection (an
    /// iPhone folder) applies the change here so the row doesn't flash back before it reloads.
    var didCommit: @MainActor (String, InboxMailAction) -> Void = { _, _ in }

    private let mailbox: MailboxController
    var mailboxForTesting: MailboxController { mailbox }
    private let refreshBus: MailboxRefreshBus
    private let commitDelay: Duration
    /// Runs an action on the backend: the action, the message, and the mailbox
    /// it was taken in (nil when the view isn't one mailbox).
    private let performAction: @MainActor (InboxMailAction, String, String?) async -> InboxMailActionOutcome
    private let sleep: @Sendable (Duration) async throws -> Void
    private var overlays: [String: OptimisticMailboxOverlay] = [:]
    /// Ask Mail batch messages that committed; their overlays stay until the batch settles.
    private var askMailCommittedMessageIDs: Set<String> = []

    private struct GraceEntry {
        let undo: PendingUndo
        let token: OptimisticMutationToken<String>
        let restore: () -> Void
        var cancelled = false
        var skipWait = false
    }
    private var grace: [String: GraceEntry] = [:]
    /// The in-flight grace-period waits, keyed by `PendingUndo.id`; cancelling one ends its wait.
    private var graceWaits: [UUID: Task<Void, Never>] = [:]
    /// The settle tasks `perform` started, until each finishes.
    private var settles: [UUID: Task<Void, Never>] = [:]

    /// True while an archive or delete is waiting out its grace period.
    var hasPendingGraceActions: Bool { !grace.isEmpty }

    convenience init(
        mailbox: MailboxController,
        refreshBus: MailboxRefreshBus,
        commitDelay: Duration,
        perform: @escaping @MainActor (InboxMailAction, String) async -> InboxMailActionOutcome,
        reproject: @escaping @MainActor () -> Void,
        reportFailure: @escaping @MainActor (String) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(
            mailbox: mailbox, refreshBus: refreshBus, commitDelay: commitDelay,
            performInMailbox: { action, id, _ in await perform(action, id) },
            reproject: reproject, reportFailure: reportFailure, sleep: sleep
        )
    }

    init(
        mailbox: MailboxController,
        refreshBus: MailboxRefreshBus,
        commitDelay: Duration,
        performInMailbox perform: @escaping @MainActor (InboxMailAction, String, String?) async -> InboxMailActionOutcome,
        reproject: @escaping @MainActor () -> Void,
        reportFailure: @escaping @MainActor (String) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.mailbox = mailbox
        self.refreshBus = refreshBus
        self.commitDelay = commitDelay
        self.performAction = perform
        self.reproject = reproject
        self.reportFailure = reportFailure
        self.sleep = sleep
        self.overlayState = MailboxOverlayProjectionState()
        self.mutations = OptimisticMutationCoordinator<String>()
    }

    /// Fire-and-forget mailbox action for rows, the reader and keyboard commands.
    /// `shownIn` is the mailbox the row or conversation was shown in, so an
    /// archive or delete acts on that copy of the message.
    func perform(_ action: InboxMailAction, messageID: String, shownIn mailboxPath: String? = nil) {
        let settle = beginMessageAction(action, messageID: messageID, shownIn: mailboxPath, origin: .mailbox)
        let id = UUID()
        settles[id] = Task { [weak self] in
            _ = await settle()
            self?.settles[id] = nil
        }
    }

    /// The same action as `perform`, awaited: returns `true` only when it succeeded.
    func performReturningOutcome(
        _ action: InboxMailAction, messageID: String, shownIn mailboxPath: String? = nil, origin: Origin
    ) async -> Bool {
        await beginMessageAction(action, messageID: messageID, shownIn: mailboxPath, origin: origin)()
    }

    /// Cancels the pending grace-period action: its row always comes back, and the reader or
    /// selection it left is restored only when the user hasn't navigated since (the rule a
    /// failed action follows). Does nothing once the action has committed.
    func undo() {
        guard let undo = pendingUndo,
              var entry = grace[undo.messageID],
              entry.undo.id == undo.id,
              !entry.cancelled
        else { return }
        entry.cancelled = true
        grace[undo.messageID] = entry
        pendingUndo = nil
        graceWaits[undo.id]?.cancel()
        // A newer action on the row already replaced this one's overlay; leave it alone.
        guard mutations.resolve(entry.token, as: .rolledBack) == .rolledBack else { return }
        setOverlay(nil, for: undo.messageID)
        entry.restore()
        reproject()
    }

    /// Ends every grace period now, so pending actions commit without waiting (for example,
    /// before the app is suspended).
    func commitPendingNow() {
        for key in grace.keys { grace[key]?.skipWait = true }
        wakeSleepers()
    }

    /// Ends every grace period now and waits until the backend has answered for every started
    /// action. Call before the app is suspended or the runtime is replaced.
    func commitPendingAndWait() async {
        commitPendingNow()
        await waitForStartedActions()
    }

    /// Waits until every action `perform` has started so far has settled, without ending any
    /// grace period.
    func waitForStartedActions() async {
        for task in Array(settles.values) {
            await task.value
        }
    }

    /// Marks every listed message read as one batch: one reprojection and one mailbox refresh,
    /// like an Ask Mail batch. Returns how many succeeded.
    @discardableResult
    func markAllRead(_ messageIDs: [String]) async -> Int {
        var succeeded = 0
        for messageID in messageIDs {
            if await performReturningOutcome(.markRead, messageID: messageID, origin: .askMailBatch) {
                succeeded += 1
            }
        }
        askMailActionsSettled()
        return succeeded
    }

    /// One Ask Mail batch finished: drop its committed overlays (unless a newer action on that
    /// row is pending) and refresh the mailbox once.
    func askMailActionsSettled() {
        let committed = askMailCommittedMessageIDs
        askMailCommittedMessageIDs = []
        for messageID in committed where !mutations.isPending(messageID) {
            setOverlay(nil, for: messageID)
        }
        reproject()
        refreshBus.bump()
    }

    /// Archive/delete from the mailbox always clears the selection (as it always has); an Ask
    /// Mail batch clears it only when the mutated message is the selected one.
    static func archiveClearsSelection(
        origin: Origin,
        selectedMessageID: String?,
        mutatedMessageID: String
    ) -> Bool {
        origin == .mailbox || selectedMessageID == mutatedMessageID
    }

    /// Applies the optimistic overlay (and leaves the reader for archive/delete) synchronously,
    /// then returns the step that performs the action and settles it: committed on success,
    /// rolled back with navigation restored on failure.
    private func beginMessageAction(
        _ action: InboxMailAction,
        messageID: String,
        shownIn mailboxPath: String?,
        origin: Origin
    ) -> @MainActor () async -> Bool {
        // A list action in an open account folder acts on that folder's copy.
        let mailboxPath = mailboxPath ?? (origin == .mailbox ? mailbox.selectedFolder?.path : nil)
        // A newer action on a row whose archive or delete is waiting ends that one's Undo now,
        // and its wait too: it would only find itself superseded at the end of the window, and
        // until then `hasPendingGraceActions` keeps a background commit or a switch waiting.
        if pendingUndo?.messageID == messageID { pendingUndo = nil }
        if var superseded = grace[messageID] {
            superseded.skipWait = true
            grace[messageID] = superseded
            graceWaits[superseded.undo.id]?.cancel()
        }
        let token = mutations.begin(for: messageID)
        let priorSelection = mailbox.selectedMessageID
        let priorNavigation = mailbox.mailboxNavigation
        let priorScrollItems = mailbox.currentMailboxScrollItems
        setOverlay(.init(rowID: messageID, action: action), for: messageID)
        if action.removesMessage {
            if case let .reader(openMessageID, _) = mailbox.mailboxNavigation.route,
               openMessageID == messageID {
                let survivingScrollItems = mailbox.currentMailboxScrollItems.filter {
                    $0.id != MailboxScrollID.message(openMessageID)
                }
                mailbox.currentMailboxScrollItems = survivingScrollItems
                mailbox.mailboxNavigation.returnFromReader()
            }
            if Self.archiveClearsSelection(
                origin: origin,
                selectedMessageID: mailbox.selectedMessageID,
                mutatedMessageID: messageID
            ) {
                mailbox.selectedMessageID = nil
            }
        }
        let optimisticNavigation = MailboxOptimisticNavigationTransition(
            optimisticIntent: mailbox.currentNavigationIntent()
        )
        // An Ask Mail batch reprojects once when it settles (`askMailActionsSettled`), not per message.
        if origin == .mailbox { reproject() }

        let usesGrace = commitDelay > .zero
            && origin == .mailbox
            && action.removesMessage
        let undoID = UUID()
        if usesGrace {
            let entry = GraceEntry(
                undo: PendingUndo(id: undoID, messageID: messageID, action: action),
                token: token,
                restore: { [weak self] in
                    guard let self,
                          optimisticNavigation.shouldRestoreNavigation(
                              currentIntent: self.mailbox.currentNavigationIntent()
                          ) else { return }
                    self.mailbox.selectedMessageID = priorSelection
                    self.mailbox.mailboxNavigation = priorNavigation
                    self.mailbox.currentMailboxScrollItems = priorScrollItems
                }
            )
            grace[messageID] = entry
            pendingUndo = entry.undo
        }

        return { [self] in
            if usesGrace {
                guard await waitOutGracePeriod(undoID, messageID: messageID, token: token) else {
                    return false
                }
            }
            switch await performAction(action, messageID, mailboxPath) {
            case .succeeded:
                guard mutations.resolve(token, as: .committed) == .committed else { return true }
                didCommit(messageID, action)
                if origin == .askMailBatch {
                    // Keep the overlay until the batch settles and the mailbox refreshes once.
                    askMailCommittedMessageIDs.insert(messageID)
                    return true
                }
                setOverlay(nil, for: messageID)
                refreshBus.bump()
                return true
            case .failed(let message):
                guard mutations.resolve(token, as: .rolledBack) == .rolledBack else { return false }
                setOverlay(nil, for: messageID)
                if optimisticNavigation.shouldRestoreNavigation(
                    currentIntent: mailbox.currentNavigationIntent()
                ) {
                    mailbox.selectedMessageID = priorSelection
                    mailbox.mailboxNavigation = priorNavigation
                    mailbox.currentMailboxScrollItems = priorScrollItems
                }
                if origin == .mailbox {
                    reportFailure(message)
                    reproject()
                }
                return false
            }
        }
    }

    /// Waits out one action's grace period and ends it. Returns `false` when the action must
    /// not reach the backend: it was undone, or a newer action on the row replaced it.
    private func waitOutGracePeriod(
        _ undoID: UUID,
        messageID: String,
        token: OptimisticMutationToken<String>
    ) async -> Bool {
        if let entry = grace[messageID], entry.undo.id == undoID, !entry.cancelled, !entry.skipWait {
            let wait = Task { [sleep, commitDelay] in _ = try? await sleep(commitDelay) }
            graceWaits[undoID] = wait
            await wait.value
            graceWaits[undoID] = nil
        }
        var entry: GraceEntry?
        if grace[messageID]?.undo.id == undoID {
            entry = grace.removeValue(forKey: messageID)
        }
        if pendingUndo?.id == undoID { pendingUndo = nil }
        if entry?.cancelled == true || !mutations.isPending(messageID) || mutations.isSuperseded(token) {
            return false
        }
        return true
    }

    /// Cancels every in-flight grace wait, so its `try? await sleep` returns at once.
    private func wakeSleepers() {
        for wait in graceWaits.values { wait.cancel() }
    }

    private func setOverlay(_ overlay: OptimisticMailboxOverlay?, for messageID: String) {
        overlays[messageID] = overlay
        overlayState.replaceOverlays(with: overlays)
    }
}
