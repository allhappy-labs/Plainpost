import Foundation

/// The one place that decides where Archive puts a message. Every direct
/// archive (the device and Mac runtime, the Mac's Node fallback, the Smart
/// Inbox batch) moves to `resolve(...)`, and the folder list labels the same
/// mailbox Archive.
///
/// In order:
/// 1. the mailbox the server marks `\Archive` (SPECIAL-USE), whatever its name;
/// 2. on Gmail (a mailbox under `[Gmail]/` or `[Google Mail]/`), All Mail: the
///    `\All` mailbox, or `All Mail` there by name. A move from INBOX to All
///    Mail is how Gmail archives over IMAP: it removes the Inbox label;
/// 3. a mailbox named `Archive` (any case) at the top level or under INBOX;
/// 4. elsewhere, a `\All` mailbox when nothing above exists.
/// Without any of these the account has no Archive, and Archive refuses
/// before any command that changes mail.
public enum ArchiveMailbox {
    public static let noArchiveMessage = "This account has no Archive folder, so the message wasn't archived."

    /// The destination every client asked for before the account's own
    /// Archive was resolved. Requesting it means "this account's Archive".
    public static let defaultName = "Archive"

    /// The account's Archive among its listed mailboxes. Nil when it has none.
    public static func path(in mailboxes: [Mailbox]) -> String? {
        if let marked = mailboxes.first(where: { isSpecialUse($0.specialUse, "\\Archive") }) {
            return marked.path
        }
        if isGmail(mailboxes) {
            if let all = mailboxes.first(where: { isSpecialUse($0.specialUse, "\\All") }) { return all.path }
            if let named = mailboxes.first(where: { isUnmarked($0) && isGmailAllMailName($0.path) }) { return named.path }
        }
        if let named = mailboxes
            .filter({ isUnmarked($0) && candidateName(of: $0.path)?.caseInsensitiveCompare(defaultName) == .orderedSame })
            .min(by: { ($0.path.count, $0.path) < ($1.path.count, $1.path) }) {
            return named.path
        }
        return mailboxes.first(where: { isSpecialUse($0.specialUse, "\\All") })?.path
    }

    /// Where an archive that asked for `requested` goes: the account's Archive
    /// for nil or the old default name; a folder the account has, spelled as
    /// the server lists it; or, when the cached list doesn't know it yet, the
    /// explicitly named folder itself. Nil when the account has no Archive.
    public static func destination(requested: String?, in mailboxes: [Mailbox]) -> String? {
        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty,
           requested.caseInsensitiveCompare(defaultName) != .orderedSame {
            return mailboxes.first { $0.path.caseInsensitiveCompare(requested) == .orderedSame }?.path ?? requested
        }
        return path(in: mailboxes)
    }

    /// Whether an archive of the copy in `sourceMailbox` has nothing to do: the
    /// cached folder list already names that mailbox as the destination (for
    /// example a Gmail message opened from search whose only copy is in All
    /// Mail). Such an archive sends nothing and changes nothing.
    public static func isAlreadyArchived(sourceMailbox: String, requested: String?, cachedMailboxes: [Mailbox]) -> Bool {
        destination(requested: requested, in: cachedMailboxes)?.caseInsensitiveCompare(sourceMailbox) == .orderedSame
    }

    /// Whether a reply that archived into `destination` answers a request for
    /// `requested`: any Archive answers nil or the default name (the account's
    /// own Archive is resolved by the service); a named folder must match.
    public static func answers(_ destination: String?, requested: String?) -> Bool {
        guard let destination, !destination.isEmpty else { return false }
        guard let requested, !requested.isEmpty, requested.caseInsensitiveCompare(defaultName) != .orderedSame else {
            return true
        }
        return destination.caseInsensitiveCompare(requested) == .orderedSame
    }

    /// The destination for an archive on `client`: from the cached folder
    /// list, else from the server's LIST (the cached list may predate the
    /// folder). Throws `validationFailed(noArchiveMessage)` when the account
    /// has no Archive, before any UID command.
    public static func resolve(
        requested: String?, client: IMAPClientProtocol, cachedMailboxes: [Mailbox]
    ) async throws -> String {
        if let destination = destination(requested: requested, in: cachedMailboxes) { return destination }
        if let destination = destination(requested: requested, in: try await client.listMailboxes()) { return destination }
        throw PlainpostError.validationFailed(noArchiveMessage)
    }

    /// Whether this mailbox is the account's Archive. With the account's folder
    /// list it is exactly the resolved one (Gmail's All Mail, not a Dovecot
    /// virtual `\All` beside a real Archive); without it, the mailbox alone
    /// decides by the same rules.
    public static func isArchive(path: String, specialUse: String?, accountMailboxes: [Mailbox] = []) -> Bool {
        if let resolved = Self.path(in: accountMailboxes) {
            return resolved == path
        }
        let alone = Mailbox(id: MailboxID(path), accountID: AccountID(""), name: path, path: path, specialUse: specialUse)
        return Self.path(in: [alone]) != nil
    }

    /// Gmail's folders live under `[Gmail]/` (or `[Google Mail]/` in some regions).
    public static func isGmail(_ mailboxes: [Mailbox]) -> Bool {
        mailboxes.contains { gmailParent(of: $0.path) != nil }
    }

    private static func isSpecialUse(_ specialUse: String?, _ flag: String) -> Bool {
        specialUse?.caseInsensitiveCompare(flag) == .orderedSame
    }

    /// A mailbox the server marks as something else is never Archive by name.
    private static func isUnmarked(_ mailbox: Mailbox) -> Bool {
        mailbox.specialUse?.isEmpty ?? true
    }

    private static func gmailParent(of path: String) -> String? {
        ["[Gmail]/", "[Google Mail]/"].first { path.count > $0.count && path.uppercased().hasPrefix($0.uppercased()) }
    }

    private static func isGmailAllMailName(_ path: String) -> Bool {
        guard let parent = gmailParent(of: path) else { return false }
        return String(path.dropFirst(parent.count)).caseInsensitiveCompare("All Mail") == .orderedSame
    }

    /// The folder's own name when it sits where an Archive can: at the top
    /// level or directly under INBOX. Nil for anything nested deeper.
    private static func candidateName(of rawPath: String) -> String? {
        let path = TrashMailbox.decodeModifiedUTF7(rawPath)
        for parent in ["INBOX/", "INBOX."] where path.count > parent.count && path.uppercased().hasPrefix(parent) {
            let name = String(path.dropFirst(parent.count))
            return name.contains("/") ? nil : name
        }
        return path.contains("/") ? nil : path
    }
}
