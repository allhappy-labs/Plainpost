import PlainpostAccounts
import PlainpostCore

/// Archive or Delete as a row's main removal. Gmail accounts archive (Gmail keeps All
/// Mail); every other account deletes. A per-account setting arrives in sub-project 2.
enum MailRemovalPolicy {
    static func primaryAction(for account: Account?) -> InboxMailAction {
        guard let account else { return .delete }
        if MailProviderProfile.gmail.matches(account) { return .archive }
        let domain = account.email.rawValue.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return domain == "gmail.com" || domain == "googlemail.com" ? .archive : .delete
    }

    static func secondaryAction(for primary: InboxMailAction) -> InboxMailAction {
        primary == .archive ? .delete : .archive
    }

    static func title(for action: InboxMailAction) -> String {
        switch action {
        case .archive: "Archive"
        case .deletePermanently: "Delete Permanently"
        default: "Delete"
        }
    }

    static func systemImage(for action: InboxMailAction) -> String {
        action == .archive ? "archivebox" : "trash"
    }
}
