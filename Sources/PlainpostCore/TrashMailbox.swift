import Foundation

/// The one place that decides whether a mailbox is Trash. Delete uses it to pick
/// where a message goes, the folder list uses it to label Trash (and offer
/// "Delete Permanently"), and Ask Mail uses it to leave Trash out.
///
/// A mailbox is Trash when the server marks it `\Trash` (SPECIAL-USE). A mailbox
/// the server marks as something else never is. Without a mark, a mailbox is
/// Trash when its name is a known Trash name (`Trash`, iCloud's `Deleted
/// Messages`, Outlook's `Deleted Items`, Gmail's `Bin`, and common localized
/// names) and it sits at the top level, under `INBOX`, or under `[Gmail]` or
/// `[Google Mail]`. A user folder such as `Projects/Deleted` is not Trash.
public enum TrashMailbox {
    /// Known Trash names, lowercased, most likely first.
    static let knownNames: [String] = [
        "trash", "deleted messages", "deleted items", "bin", "deleted",
        // Localized (Gmail, Outlook, Apple and common hosts).
        "papierkorb", "gelöschte elemente", "gelöschte objekte",
        "corbeille", "éléments supprimés",
        "papelera", "elementos eliminados",
        "cestino", "posta eliminata", "elementi eliminati",
        "lixeira", "lixo", "itens excluídos", "itens eliminados",
        "prullenbak", "verwijderde items",
        "papperskorgen", "borttagna objekt",
        "papirkurv", "slettede elementer", "slettet post",
        "roskakori", "poistetut",
        "kosz", "elementy usunięte",
        "koš", "odstraněná pošta",
        "корзина", "удаленные", "удалённые",
        "çöp kutusu", "çöp",
        "ゴミ箱", "削除済みアイテム",
        "垃圾桶", "已删除邮件", "已删除",
        "휴지통",
    ]

    /// The account's Trash among its listed mailboxes: the `\Trash` mailbox,
    /// else the best-named one. Nil when none is Trash.
    public static func path(in mailboxes: [Mailbox]) -> String? {
        if let special = mailboxes.first(where: { isTrashSpecialUse($0.specialUse) }) {
            return special.path
        }
        let named = mailboxes.compactMap { mailbox -> (rank: Int, path: String)? in
            guard let rank = nameRank(path: mailbox.path, specialUse: mailbox.specialUse) else { return nil }
            return (rank, mailbox.path)
        }
        return named.min { ($0.rank, $0.path) < ($1.rank, $1.path) }?.path
    }

    /// Whether this one mailbox is Trash, by the rules above.
    public static func isTrash(path: String, specialUse: String?) -> Bool {
        isTrashSpecialUse(specialUse) || nameRank(path: path, specialUse: specialUse) != nil
    }

    /// Whether this mailbox is Trash given the account's whole folder list: when
    /// the server marks one mailbox `\Trash`, that one is the Trash and names no
    /// longer count (an iCloud account's legacy "Trash" beside its marked
    /// "Deleted Messages" is an ordinary folder).
    public static func isTrash(path: String, specialUse: String?, accountMailboxes: [Mailbox]) -> Bool {
        if isTrashSpecialUse(specialUse) { return true }
        if accountMailboxes.contains(where: { isTrashSpecialUse($0.specialUse) }) { return false }
        return isTrash(path: path, specialUse: specialUse)
    }

    /// Whether a path is Trash by name alone, for callers without the folder list.
    public static func isTrashPath(_ path: String) -> Bool {
        isTrash(path: path, specialUse: nil)
    }

    static func isTrashSpecialUse(_ specialUse: String?) -> Bool {
        specialUse?.caseInsensitiveCompare("\\Trash") == .orderedSame
    }

    private static func nameRank(path: String, specialUse: String?) -> Int? {
        // A mailbox the server marks as something else is never Trash.
        guard specialUse?.isEmpty ?? true, let name = trashCandidateName(of: path) else { return nil }
        return knownNames.firstIndex(of: name.lowercased())
    }

    /// The folder's own name when it sits where a Trash can: at the top level,
    /// or directly under INBOX, [Gmail] or [Google Mail]. Nil for anything
    /// nested deeper or under another parent.
    private static func trashCandidateName(of rawPath: String) -> String? {
        let path = decodeModifiedUTF7(rawPath)
        for parent in ["[Gmail]/", "[Google Mail]/", "INBOX/", "INBOX."] {
            if path.count > parent.count, path.uppercased().hasPrefix(parent.uppercased()) {
                let name = String(path.dropFirst(parent.count))
                return name.contains("/") ? nil : name
            }
        }
        return path.contains("/") ? nil : path
    }

    /// IMAP mailbox names are modified UTF-7 (RFC 3501 5.1.3): "&" starts a
    /// base64 run of UTF-16BE ending in "-", with "," for "/". Undecodable
    /// input comes back unchanged.
    static func decodeModifiedUTF7(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "&" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }
            guard let end = value[index...].firstIndex(of: "-") else { return value }
            let encoded = value[value.index(after: index)..<end]
            if encoded.isEmpty {
                result.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                guard let data = Data(base64Encoded: base64), data.count % 2 == 0,
                      let decoded = String(data: data, encoding: .utf16BigEndian)
                else { return value }
                result.append(decoded)
            }
            index = value.index(after: end)
        }
        return result
    }
}
