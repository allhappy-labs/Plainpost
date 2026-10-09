import Combine
import Foundation
import PlainpostCore

/// One of an account's folders, as a Mailboxes list shows it.
struct MailboxFolder: Equatable, Identifiable, Sendable {
    enum Role: Equatable, Sendable { case inbox, drafts, sent, archive, trash, junk, other }

    let id: String
    let accountID: AccountID
    /// The last component of the folder's name ("Sent Mail" for `[Gmail]/Sent Mail`).
    let name: String
    let path: String
    let role: Role
    let unread: Int

    /// The folder's symbol in a Mailboxes list or the Mac sidebar.
    static func systemImage(for role: Role) -> String {
        switch role {
        case .inbox: "tray"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .other: "folder"
        }
    }
}

/// Whether an account is syncing, as its Mailboxes section says it.
enum AccountSyncStatus: Equatable, Sendable {
    case ok
    /// The last sync of the account failed; the others go on.
    case failed
    case needsSignIn
    case syncNodeUnreachable
    /// The Sync Node no longer serves the account; its mail here stays until it's removed.
    case noLongerOnSyncNode

    /// The section's status line; nil while the account syncs.
    var message: String? {
        switch self {
        case .ok: nil
        case .failed: "Couldn't sync"
        case .needsSignIn: "Sign in again to sync"
        case .syncNodeUnreachable: "Sync Node unreachable"
        case .noLongerOnSyncNode: "No longer on your Sync Node"
        }
    }

    /// The account settings row under the section's status, where the account's sign-in
    /// lives; nil while nothing there helps.
    var settingsTitle: String? {
        switch self {
        case .ok, .failed: nil
        case .needsSignIn: "Sign In Again"
        case .syncNodeUnreachable, .noLongerOnSyncNode: "Account Settings"
        }
    }
}

/// One account's folders, system folders first.
struct MailboxAccountSection: Equatable, Identifiable, Sendable {
    let id: AccountID
    let title: String
    let folders: [MailboxFolder]
    var status: AccountSyncStatus = .ok
}

/// Each account's folders with their unread counts, for a Mailboxes list. The model loads
/// only when asked: host visibility marks it dirty, and the session's attached activity
/// worker owns the initial load and subsequent snapshot refreshes.
/// A UI that never shows the list never pays for the query.
@MainActor
final class MailboxDirectoryModel: ObservableObject {
    /// How many mailbox rows the directory reads, across every account.
    nonisolated static let mailboxLimit = 500

    @Published private(set) var sections: [MailboxAccountSection] = []

    private let load: () async -> [MailboxAccountSection]
    private var latestRefresh = 0

    /// True while a Mailboxes screen shows the directory. Snapshot refreshes keep it current
    /// only then, so a hidden directory costs nothing and never delays other work.
    private(set) var isVisible = false
    var didBecomeVisible: @MainActor () -> Void = {}

    init(load: @escaping () async -> [MailboxAccountSection]) {
        self.load = load
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { didBecomeVisible() }
        else { invalidate() }
    }

    /// Keep cached sections, but reject a load admitted for an older source or visibility.
    func invalidate() {
        latestRefresh &+= 1
    }

    /// Unread messages across every account's inbox: the Mailboxes count for Smart Inbox,
    /// All Inboxes and Unread (messages, like every folder count).
    var inboxUnreadCount: Int {
        sections.flatMap(\.folders).filter { $0.role == .inbox }.reduce(0) { $0 + $1.unread }
    }

    /// Loads the directory. When refreshes overlap, the newest one's result wins.
    func refresh() async {
        guard !Task.isCancelled else { return }
        latestRefresh += 1
        let refresh = latestRefresh
        let loaded = await load()
        guard !Task.isCancelled, refresh == latestRefresh, loaded != sections else { return }
        sections = loaded
    }

    /// Loads only while a host is showing the directory, including its first load.
    /// Hidden source changes remain dirty until the host next becomes visible.
    func refreshIfLoaded() async {
        guard isVisible else { return }
        await refresh()
    }

    // MARK: - Building the directory

    /// The folder's role: its IMAP special-use flag if it has one that names a role, or else
    /// a common name for its last path component. Only the top-level `INBOX` is the inbox.
    nonisolated static func role(
        path: String, specialUse: String?, accountMailboxes: [Mailbox] = []
    ) -> MailboxFolder.Role {
        if let specialUse, let role = specialUseRoles[specialUse.lowercased()] {
            return role
        }
        if path.caseInsensitiveCompare("INBOX") == .orderedSame {
            return .inbox
        }
        // Trash is decided in one place, the same one Delete uses.
        if TrashMailbox.isTrash(path: path, specialUse: specialUse, accountMailboxes: accountMailboxes) {
            return .trash
        }
        // So is Archive: the folder Archive moves to (Gmail's All Mail), and no other.
        if ArchiveMailbox.isArchive(path: path, specialUse: specialUse, accountMailboxes: accountMailboxes) {
            return .archive
        }
        return nameRoles[lastPathComponent(of: path).lowercased()] ?? .other
    }

    /// Inbox, drafts, sent, archive, junk and trash, then the other folders by name.
    nonisolated static func ordered(_ folders: [MailboxFolder]) -> [MailboxFolder] {
        folders.sorted { lhs, rhs in
            let lhsRank = rank(of: lhs.role)
            let rhsRank = rank(of: rhs.role)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.path < rhs.path
            }
        }
    }

    /// One section per account, in `accounts` order. An account's folders are its
    /// `mailboxes` rows plus every path its `unreadCounts` names without a row (a Node
    /// mirror account has memberships but no rows); paths match ignoring case, and a
    /// folder missing from the counts has no unread mail.
    nonisolated static func sections(
        accounts: [Account],
        mailboxes: [Mailbox],
        unreadCounts: [AccountID: [String: Int]]
    ) -> [MailboxAccountSection] {
        accounts.map { account in
            let counts = Dictionary(
                (unreadCounts[account.id] ?? [:]).map { ($0.key.lowercased(), $0.value) },
                uniquingKeysWith: +
            )
            var seenPaths = Set<String>()
            var folders: [MailboxFolder] = []
            let accountMailboxes = mailboxes.filter { $0.accountID == account.id }
            func add(path: String, name: String, specialUse: String?) {
                guard seenPaths.insert(path.lowercased()).inserted else { return }
                let role = role(path: path, specialUse: specialUse, accountMailboxes: accountMailboxes)
                folders.append(MailboxFolder(
                    id: "\(account.id.rawValue)|\(path)",
                    accountID: account.id,
                    name: role == .inbox && path.caseInsensitiveCompare("INBOX") == .orderedSame
                        ? "Inbox" : lastPathComponent(of: name.isEmpty ? path : name),
                    path: path,
                    role: role,
                    unread: counts[path.lowercased()] ?? 0
                ))
            }
            for mailbox in mailboxes where mailbox.accountID == account.id {
                add(path: mailbox.path, name: mailbox.name, specialUse: mailbox.specialUse)
            }
            for path in (unreadCounts[account.id] ?? [:]).keys.sorted() {
                add(path: path, name: path, specialUse: nil)
            }
            return MailboxAccountSection(
                id: account.id,
                title: account.displayName.isEmpty ? account.email.rawValue : account.displayName,
                folders: ordered(folders)
            )
        }
    }

    /// Unread, non-deleted messages per mailbox path, from messages already in hand (a Sync
    /// Node's snapshot page). Every path is a key; paths group ignoring case.
    nonisolated static func unreadCounts(messages: [MessageSummary]) -> [String: Int] {
        var keys: [String: String] = [:]
        var counts: [String: Int] = [:]
        for message in messages {
            let key = keys[message.mailboxPath.lowercased(), default: message.mailboxPath]
            keys[message.mailboxPath.lowercased()] = key
            counts[key, default: 0] += message.isSeen || message.isDeleted ? 0 : 1
        }
        return counts
    }

    private nonisolated static let specialUseRoles: [String: MailboxFolder.Role] = [
        "\\inbox": .inbox,
        "\\drafts": .drafts,
        "\\sent": .sent,
        "\\trash": .trash,
        "\\junk": .junk,
    ]

    private nonisolated static let nameRoles: [String: MailboxFolder.Role] = [
        "drafts": .drafts,
        "sent": .sent, "sent mail": .sent, "sent items": .sent, "sent messages": .sent,
        "junk": .junk, "spam": .junk,
    ]

    private nonisolated static func rank(of role: MailboxFolder.Role) -> Int {
        switch role {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .archive: 3
        case .junk: 4
        case .trash: 5
        case .other: 6
        }
    }

    /// The folder's own name: after the last "/", or after the last "." for servers (Courier,
    /// Dovecot's default) that nest folders as `INBOX.Sent`.
    private nonisolated static func lastPathComponent(of path: String) -> String {
        if !path.contains("/"), path.uppercased().hasPrefix("INBOX.") {
            return path.split(separator: ".").last.map(String.init) ?? path
        }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
