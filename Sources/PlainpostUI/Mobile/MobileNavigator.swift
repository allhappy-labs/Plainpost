import Foundation
import PlainpostCore

/// A mailbox the iPhone can show as a list.
enum MobileMailbox: Hashable, Sendable {
    case smartInbox
    case allInboxes
    case unread
    case folder(MailFolderRef)

    var title: String {
        switch self {
        case .smartInbox: "Smart Inbox"
        case .allInboxes: "All Inboxes"
        case .unread: "Unread"
        case let .folder(ref): ref.name
        }
    }

    /// The shared destination whose thread a conversation opened from here reads.
    var destination: PlainpostDestination {
        self == .smartInbox ? .smartInbox : .allInboxes
    }

    /// The mailbox an external open (a notification, Ask Mail) lands in when none is shown.
    static func forDestination(_ destination: PlainpostDestination) -> MobileMailbox {
        destination == .smartInbox ? .smartInbox : .allInboxes
    }
}

extension MobileMailbox {
    /// The list a conversation's Archive and Delete belong to: the list under the
    /// conversation only when that list shows the message. A conversation opened
    /// from Ask Mail, a notification or Search can sit on an unrelated list; it
    /// then gets nil, so the action uses the message's own copy (INBOX first)
    /// and its removal actions and titles ignore that list.
    static func actionList(under list: MobileMailbox?, messageID: String, listMessageIDs: [String]) -> MobileMailbox? {
        guard let list, listMessageIDs.contains(messageID) else { return nil }
        return list
    }

    /// The mailbox whose copy of a message an action here touches: the folder
    /// itself, or INBOX for the inbox lists (they list Inbox copies).
    var shownMailboxPath: String {
        if case let .folder(ref) = self { return ref.path }
        return "INBOX"
    }

    /// The removal actions a row or conversation opened from here offers, primary first.
    /// Inside an archive folder Archive would only copy the message onto itself, so Delete
    /// is the one action left.
    /// `offersPermanentDelete` is false where nothing can erase (a Sync Node
    /// runtime); Delete is then left out of Trash, where it would do nothing.
    func removalActions(primary: InboxMailAction, offersPermanentDelete: Bool = true) -> [InboxMailAction] {
        let actions = [primary, MailRemovalPolicy.secondaryAction(for: primary)]
        guard case let .folder(ref) = self else { return actions }
        switch ref.role {
        case .archive:
            return actions.filter { $0 != .archive }
        case .trash:
            // Only here, in a folder the shared Trash rules recognize, is Delete
            // the explicit "Delete Permanently" that erases.
            guard offersPermanentDelete else { return actions.filter { $0 != .delete } }
            return actions.map { $0 == .delete ? .deletePermanently : $0 }
        default:
            return actions
        }
    }

    /// A removal action's title here.
    func removalTitle(for action: InboxMailAction) -> String {
        MailRemovalPolicy.title(for: action)
    }

    /// What the list says when it has no rows: a chip, the unread filter, or the folder's own
    /// wording ("No Sent Mail", "Messages you send appear here.").
    func emptyState(unreadOnly: Bool, categoryTitle: String?) -> (title: String, detail: String) {
        let unread = unreadOnly || self == .unread
        let caughtUp = "You're all caught up."
        if let categoryTitle {
            return ("Nothing in \(categoryTitle)", unread ? caughtUp : "New messages appear here.")
        }
        if unread { return ("No Unread Mail", caughtUp) }
        guard case let .folder(ref) = self else { return ("No Mail", "New messages appear here.") }
        switch ref.role {
        case .inbox: return ("No Mail", "New messages appear here.")
        case .drafts: return ("No Drafts", "Drafts you save appear here.")
        case .sent: return ("No Sent Mail", "Messages you send appear here.")
        case .archive: return ("No Archived Mail", "Messages you archive appear here.")
        case .junk: return ("No Junk Mail", "Messages in \(ref.name) appear here.")
        case .trash: return ("Trash Is Empty", "Messages in \(ref.name) appear here.")
        case .other: return ("No Mail", "Messages in \(ref.name) appear here.")
        }
    }

    /// The list's navigation subtitle: "reader@example.test · 3 unread", "All accounts".
    static func subtitle(accountTitles: [String], unread: Int) -> String {
        let scope = accountTitles.count == 1 ? accountTitles[0] : "All accounts"
        return unread > 0 ? "\(scope) · \(unread) unread" : scope
    }
}

/// One screen on the iPhone navigation stack. An empty path is the Mailboxes root.
enum MobileRoute: Hashable, Sendable {
    case mailbox(MobileMailbox)
    case conversation(messageID: String)
    case search
    case approvals
    case approval(requestID: String)
    case settings
    case settingsDestination(PlainpostSettingsDestination)
}

/// A shared-state change the shell makes after the system pops screens.
enum MobileNavigationEffect: Equatable, Sendable {
    case returnFromConversation
    case closeSearch
    case leaveMailbox
    /// Search moved the shared destination; point it back at the mailbox under it.
    case showMailbox(MobileMailbox)
}

/// The iPhone back stack, the only one. The conversation part of the path follows the
/// shared `MailboxController`; search and utilities stack above; system pops come back
/// through `applySystemPath`, which reports what the shared state must undo.
struct MobileNavigator: Equatable, Sendable {
    static let launchPath: [MobileRoute] = [.mailbox(.smartInbox)]

    private(set) var path: [MobileRoute]

    init(path: [MobileRoute] = MobileNavigator.launchPath) {
        self.path = path
    }

    mutating func applySmartInboxEnabled(_ enabled: Bool) {
        guard !enabled else { return }
        // Retire the reader and all utility breadcrumbs above the hidden mailbox.
        if path.contains(.mailbox(.smartInbox)) { path = [.mailbox(.allInboxes)] }
    }

    /// Rebuilds the conversation level from the shared route. A list route on the Mailboxes
    /// root or a utility screen changes nothing, so a refresh never undoes a pop.
    mutating func reconcile(destination: PlainpostDestination, route: MailboxWorkspaceRoute) {
        guard destination.workAreaKind == .mailbox else { return }
        let readerID: String?
        if case let .reader(messageID, _) = route { readerID = messageID } else { readerID = nil }

        if let searchIndex = path.firstIndex(of: .search) {
            var kept = Array(path[...searchIndex])
            if let readerID { kept.append(.conversation(messageID: readerID)) }
            path = kept
            return
        }
        if case let .mailbox(current)? = path.first {
            var rebuilt: [MobileRoute] = [.mailbox(current)]
            if let readerID { rebuilt.append(.conversation(messageID: readerID)) }
            path = rebuilt
            return
        }
        guard let readerID else { return }
        path = [.mailbox(.forDestination(destination)), .conversation(messageID: readerID)]
    }

    mutating func openMailbox(_ mailbox: MobileMailbox) {
        path = [.mailbox(mailbox)]
    }

    mutating func openSearch() {
        if let index = path.firstIndex(of: .search) {
            path = Array(path[...index])
        } else {
            path.append(.search)
        }
    }

    mutating func openApprovals() {
        if let index = path.firstIndex(of: .approvals) {
            path = Array(path[...index])
        } else {
            path.append(.approvals)
        }
    }

    mutating func openApproval(requestID: String) {
        openApprovals()
        path.append(.approval(requestID: requestID))
    }

    /// Settings always opens on its list, never on the section last shown.
    mutating func openSettings() {
        if let index = path.firstIndex(of: .settings) {
            path = Array(path[...index])
        } else {
            path.append(.settings)
        }
    }

    /// A shell built after a Settings account row switched to `pending` opens that account's
    /// page over the Settings list. A switch that landed on another account changes nothing.
    mutating func resetToLaunch() {
        path = Self.launchPath
    }

    /// A shell built for a notification that opened an account's inbox starts in All Inboxes.
    /// Only the untouched launch path follows the destination.
    mutating func adoptLaunchDestination(_ destination: PlainpostDestination) {
        guard path == Self.launchPath, destination.workAreaKind == .mailbox else { return }
        path = [.mailbox(.forDestination(destination))]
    }

    /// Accepts the path SwiftUI wrote after Back, an edge swipe or a push, and returns, top
    /// first, the state changes that undo each popped screen.
    mutating func applySystemPath(_ newPath: [MobileRoute]) -> [MobileNavigationEffect] {
        let common = zip(path, newPath).prefix { $0 == $1 }.count
        var effects: [MobileNavigationEffect] = []
        for route in path[common...].reversed() {
            switch route {
            case .conversation: effects.append(.returnFromConversation)
            case .search: effects.append(.closeSearch)
            case .mailbox: effects.append(.leaveMailbox)
            case .approvals, .approval, .settings, .settingsDestination: break
            }
        }
        path = newPath
        if effects.contains(.closeSearch),
           case let .mailbox(mailbox)? = newPath.last(where: { if case .mailbox = $0 { true } else { false } }) {
            effects.append(.showMailbox(mailbox))
        }
        return effects
    }
}

/// When a folder list reloads: on open, on every mailbox change (the refresh bus), and when
/// the snapshot refresh that change started has landed. A Direct folder reads the store,
/// already current at the bump; a Sync Node folder reads the snapshot page, replaced only
/// once that refresh finishes.
struct MobileFolderLoadKey: Equatable {
    let kind: MobileMailbox
    let refreshRevision: Int
    let completedSnapshotRefreshes: Int
}
