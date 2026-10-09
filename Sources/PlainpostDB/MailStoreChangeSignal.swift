import Foundation

public enum MailStoreChangeScope: String, CaseIterable, Sendable {
    case mailbox
    case accounts
    case operations
    case all
}

/// A property-list-safe hint that another process committed local data.
/// Receivers always reload from SQLite; the notification is never data authority.
public enum MailStoreChangeSignal {
    public static let notificationName = Notification.Name("com.marynavdovenko.Plainpost.storeChanged")
    public static let scopeUserInfoKey = "scope"

    public static func post(scope: MailStoreChangeScope = .all) {
        let userInfo = [scopeUserInfoKey: scope.rawValue]
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: userInfo
        )
#if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
#endif
    }

    public static func scope(from notification: Notification) -> MailStoreChangeScope {
        guard let rawValue = notification.userInfo?[scopeUserInfoKey] as? String,
              let scope = MailStoreChangeScope(rawValue: rawValue) else {
            return .all
        }
        return scope
    }
}
