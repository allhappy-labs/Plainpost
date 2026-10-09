import Foundation
import PlainpostCore

/// The mailbox's destination, display mode, selection and list/reader route,
/// independent of any platform UI. PlainpostRootView owns one; a future
/// iPhone UI shares it.
@MainActor
final class MailboxController: ObservableObject {
    enum Direction { case previous, next }

    @Published var selectedDestination: PlainpostDestination {
        // Only All Inboxes can be narrowed to a folder; every other destination closes it.
        didSet { if selectedDestination != .allInboxes, selectedFolder != nil { selectedFolder = nil } }
    }
    /// The account folder the Mac mail list is narrowed to, under All Inboxes; nil for the
    /// destination itself. Choosing any destination clears it.
    @Published private(set) var selectedFolder: MailFolderRef?
    @Published var selectedInboxMode: String
    @Published var selectedMessageID: String?
    @Published var mailboxNavigation: MailboxWorkspaceNavigationState
    @Published var currentMailboxScrollItems: [MailboxScrollItem]
    @Published private(set) var navigationRevision: UInt64
    /// iPhone category chips; macOS leaves this nil.
    @Published var selectedCategory: SmartInboxDisplayBundle?
    /// iPhone unread filter; macOS leaves this false.
    @Published var unreadOnly: Bool
    /// Messages opened while the unread filter was on. They stay listed, though now read,
    /// until the filter or the mailbox changes, so Back lands on them and ⌃⌄ keeps working.
    @Published private(set) var keptUnreadIDs: Set<String> = []
    /// Whether showing a list restores the message last selected in it. A split view shows
    /// that selection in its reader, so macOS and iPad keep it. The iPhone list has no visible
    /// selection, so it turns this off: a restored ID would count as a human open and mark a
    /// message read that the user can't see (for example, one just marked unread).
    var restoresListSelection = true
    private(set) var smartInboxEnabled = true

    func applySmartInboxEnabled(_ enabled: Bool) {
        smartInboxEnabled = enabled
        if !enabled && selectedDestination == .smartInbox {
            enterMailbox(.allInboxes, unreadOnly: false)
        }
    }

    private func availableDestination(_ destination: PlainpostDestination) -> PlainpostDestination {
        destination == .smartInbox && !smartInboxEnabled ? .allInboxes : destination
    }
    let scrollRuntime: MailboxScrollRuntime
    /// Called after every open/return so a platform can react (the old iOS column hack attaches here).
    var onRouteChange: (MailboxWorkspaceRoute) -> Void

    init(
        destination: PlainpostDestination,
        mode: String,
        selectedMessageID: String?,
        navigation: MailboxWorkspaceNavigationState
    ) {
        self.selectedDestination = destination
        self.selectedInboxMode = mode
        self.selectedMessageID = selectedMessageID
        self.mailboxNavigation = navigation
        self.currentMailboxScrollItems = []
        self.navigationRevision = 0
        self.selectedCategory = nil
        self.unreadOnly = false
        self.scrollRuntime = MailboxScrollRuntime()
        self.onRouteChange = { _ in }
    }

    func setUnreadOnly(_ isOn: Bool) {
        unreadOnly = isOn
        keptUnreadIDs = []
    }

    /// Clears the category chip, the unread filter and the rows it kept (leaving a mailbox).
    func resetFilters() {
        selectedCategory = nil
        setUnreadOnly(false)
    }

    /// Points the list back at `destination` after Search closes, only if opening a hit moved
    /// it. The chip and Unread Only stay: the user is back on the same list.
    func returnFromSearch(to destination: PlainpostDestination) {
        guard selectedDestination != destination else { return }
        setDestination(destination, displayMode: InboxDisplayMode.focusedList.rawValue)
        showList(currentListContext())
    }

    /// Shows `destination`'s list with its chip and filters cleared, turning Unread Only on
    /// when asked (the iPhone entering a mailbox from Mailboxes).
    func enterMailbox(_ destination: PlainpostDestination, unreadOnly: Bool) {
        setDestination(destination, displayMode: InboxDisplayMode.focusedList.rawValue)
        resetFilters()
        if unreadOnly { setUnreadOnly(true) }
        showList(currentListContext())
    }

    /// `rows` narrowed by the selected category chip and the unread filter.
    func visibleRows(_ rows: [MessageRowModel]) -> [MessageRowModel] {
        rows.filter { row in
            if let selectedCategory, SmartInboxDisplayBundle.chip(for: row.category) != selectedCategory {
                return false
            }
            return !unreadOnly || row.isUnread || keptUnreadIDs.contains(row.id)
        }
    }

    func listContext(
        destination: PlainpostDestination,
        mode: InboxDisplayMode,
        preserveActiveBundle: Bool
    ) -> MailboxListContext {
        if destination == .smartInbox, mode == .focusedList {
            if preserveActiveBundle,
               case let .list(.smartInboxBundle(bundle)) = mailboxNavigation.route {
                return .smartInboxBundle(bundle)
            }
            return .smartInboxOverview
        }
        return .mailbox(destination: destination, mode: mode)
    }

    func currentListContext() -> MailboxListContext {
        listContext(
            destination: selectedDestination,
            mode: InboxDisplayMode(rawValue: selectedInboxMode) ?? .focusedList,
            preserveActiveBundle: true
        )
    }

    func setDisplayMode(_ mode: String) {
        guard let outgoingContext = outgoingListContext() else {
            selectedInboxMode = mode
            return
        }
        MailboxNavigationBoundarySetter.setDisplayMode(
            from: selectedInboxMode,
            to: mode,
            runtime: scrollRuntime,
            selectedMessageID: selectedMessageID,
            capture: { location in
                self.saveScrollLocation(location, for: outgoingContext)
            },
            assign: { self.selectedInboxMode = $0 }
        )
    }

    /// Shows one account folder: All Inboxes narrowed to it.
    func openFolder(_ folder: MailFolderRef) {
        setDestination(.allInboxes)
        selectedFolder = folder
    }

    /// Returns to All Inboxes when the open folder's account is no longer listed: gone from the
    /// directory, or the only account left (the sidebar lists no account folders then). An
    /// empty directory hasn't loaded and changes nothing.
    func reconcileFolder(withDirectory sections: [MailboxAccountSection]) {
        guard !sections.isEmpty else { return }
        reconcileFolder(withAccounts: sections.count > 1 ? Set(sections.map(\.id)) : [])
    }

    /// Returns to All Inboxes when the open folder's account is gone.
    func reconcileFolder(withAccounts accounts: Set<AccountID>) {
        guard let selectedFolder, !accounts.contains(selectedFolder.accountID) else { return }
        setDestination(.allInboxes)
    }

    func setDestination(
        _ destination: PlainpostDestination,
        displayMode: String? = nil
    ) {
        selectedFolder = nil
        let destination = availableDestination(destination)
        guard let outgoingContext = outgoingListContext() else {
            selectedDestination = destination
            if let displayMode {
                selectedInboxMode = displayMode
            }
            return
        }
        if let displayMode {
            MailboxNavigationBoundarySetter.setDestinationAndDisplayMode(
                from: selectedDestination,
                currentDisplayMode: selectedInboxMode,
                to: destination,
                displayMode: displayMode,
                runtime: scrollRuntime,
                selectedMessageID: selectedMessageID,
                capture: { location in
                    self.saveScrollLocation(location, for: outgoingContext)
                },
                assign: { newDestination, newMode in
                    self.selectedDestination = newDestination
                    self.selectedInboxMode = newMode
                }
            )
            return
        }
        MailboxNavigationBoundarySetter.setDestination(
            from: selectedDestination,
            to: destination,
            runtime: scrollRuntime,
            selectedMessageID: selectedMessageID,
            capture: { location in
                self.saveScrollLocation(location, for: outgoingContext)
            },
            assign: { self.selectedDestination = $0 }
        )
    }

    func outgoingListContext() -> MailboxListContext? {
        guard selectedDestination.workAreaKind == .mailbox,
              case let .list(context) = mailboxNavigation.route
        else {
            return nil
        }
        return context
    }

    func readerRouteMatches(_ context: MailboxListContext) -> Bool {
        guard case let .reader(messageID, returnContext) = mailboxNavigation.route else {
            return false
        }
        return returnContext == context && selectedMessageID == messageID
    }

    func recordNavigationIntent() {
        navigationRevision &+= 1
    }

    func currentNavigationIntent() -> MailboxNavigationIntent {
        MailboxNavigationIntent(
            destination: selectedDestination,
            mode: InboxDisplayMode(rawValue: selectedInboxMode) ?? .focusedList,
            route: mailboxNavigation.route,
            selectedMessageID: selectedMessageID,
            revision: navigationRevision
        )
    }

    /// Opens `messageID` in the reader. A message opened from anywhere but the open folder's
    /// own list (search, a notification, Ask Mail) closes the folder, so the list and the
    /// reader agree; the folder list passes `keepingFolder`.
    func openMessage(
        _ messageID: String,
        destination: PlainpostDestination,
        from context: MailboxListContext,
        keepingFolder: Bool = false
    ) {
        if !keepingFolder { selectedFolder = nil }
        recordNavigationIntent()
        let mode: InboxDisplayMode
        let isSmartInboxContext: Bool
        switch context {
        case let .mailbox(contextDestination, contextMode):
            mode = contextMode
            isSmartInboxContext = contextDestination == .smartInbox
        case .smartInboxOverview, .smartInboxBundle:
            mode = .focusedList
            isSmartInboxContext = true
        }
        let availableDestination = availableDestination(destination)
        let availableContext: MailboxListContext = !smartInboxEnabled && (destination == .smartInbox || isSmartInboxContext)
            ? .mailbox(destination: availableDestination, mode: mode) : context
        mailboxNavigation.remember(mode, for: availableDestination)
        selectedDestination = availableDestination
        selectedInboxMode = mode.rawValue
        selectedMessageID = messageID
        if unreadOnly { keptUnreadIDs.insert(messageID) }
        mailboxNavigation.openReader(messageID: messageID, from: availableContext)
        onRouteChange(mailboxNavigation.route)
    }

    func openMessage(
        _ messageID: String,
        from context: MailboxListContext
    ) {
        openMessage(
            messageID,
            destination: selectedDestination,
            from: context
        )
    }

    func returnToList() {
        recordNavigationIntent()
        mailboxNavigation.returnFromReader()
        if !restoresListSelection { selectedMessageID = nil }
        onRouteChange(mailboxNavigation.route)
    }

    func showList(_ context: MailboxListContext) {
        if !restoresListSelection {
            selectedMessageID = nil
        } else if mailboxNavigation.route != .list(context) {
            selectedMessageID = mailboxNavigation.location(for: context)
                .selectedMessageID
        }
        mailboxNavigation.showList(context)
    }

    func showSmartInboxBundle(_ bundle: SmartInboxDisplayBundle) {
        guard smartInboxEnabled else { enterMailbox(.allInboxes, unreadOnly: false); return }
        recordNavigationIntent()
        showList(.smartInboxBundle(bundle))
    }

    func showSmartInboxOverview() {
        guard smartInboxEnabled else { enterMailbox(.allInboxes, unreadOnly: false); return }
        recordNavigationIntent()
        showList(.smartInboxOverview)
    }

    func saveScrollLocation(
        _ location: MailboxScrollLocation,
        for context: MailboxListContext
    ) {
        guard mailboxNavigation.route == .list(context) else { return }
        mailboxNavigation.save(location, for: context)
    }

    func resolveRestoration(
        for context: MailboxListContext,
        availableItems: [MailboxScrollItem],
        availableMessageIDs: [String],
        isRefresh: Bool
    ) -> MailboxScrollRestoration? {
        if isRefresh {
            mailboxNavigation.prepareRefreshRestoration(
                for: context,
                availableItems: availableItems,
                availableMessageIDs: availableMessageIDs
            )
        } else {
            mailboxNavigation.prepareListRestoration(
                for: context,
                availableItems: availableItems,
                availableMessageIDs: availableMessageIDs
            )
        }
        return mailboxNavigation.consumeRestoration(for: context)
    }

    func adjacentMessageID(_ direction: Direction, in orderedMessageIDs: [String]) -> String? {
        guard let current = selectedMessageID,
              let index = orderedMessageIDs.firstIndex(of: current) else { return nil }
        let target = direction == .next ? index + 1 : index - 1
        return orderedMessageIDs.indices.contains(target) ? orderedMessageIDs[target] : nil
    }
}
