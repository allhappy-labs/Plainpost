import PlainpostCore

/// Which accounts a mailbox list, count or unread total reads: every account, or a set
/// of them. An empty set reads nothing.
public enum MailboxAccountFilter: Sendable, Equatable {
    case all
    case accounts(Set<AccountID>)

    public init(_ accountID: AccountID?) {
        self = accountID.map { .accounts([$0]) } ?? .all
    }

    var isAll: Bool { self == .all }

    /// The `AND <column> IN (...)` clause for `column` and its bound values.
    func sql(column: String) -> (clause: String, values: [String]) {
        switch self {
        case .all:
            return ("", [])
        case .accounts(let ids) where ids.isEmpty:
            return ("AND 0", [])
        case .accounts(let ids):
            let sorted = ids.map(\.rawValue).sorted()
            return ("AND \(column) IN (\(sorted.map { _ in "?" }.joined(separator: ", ")))", sorted)
        }
    }
}
