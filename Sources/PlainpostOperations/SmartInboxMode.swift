import Foundation

/// How much mail this device's Smart Inbox sorts. Stored per device; never synced.
public enum SmartInboxMode: Equatable, Sendable, Codable {
    case off
    /// Only mail sent at or after `since` is classified. `since` is the moment the user chose the mode.
    case newMailOnly(since: Date)
    case allMail

    public var isEnabled: Bool { self != .off }

    public var newMailSince: Date? {
        if case .newMailOnly(let since) = self { return since }
        return nil
    }

    public static func platformDefault(now: Date) -> SmartInboxMode {
        #if os(iOS)
        .newMailOnly(since: now)
        #else
        .allMail
        #endif
    }

    /// Converts the pre-mode `Plainpost.smartInbox.enabled` boolean. `nil` means a fresh install.
    public static func migratingLegacy(enabled: Bool?, now: Date) -> SmartInboxMode {
        switch enabled {
        case nil: platformDefault(now: now)
        case false?: .off
        case true?: platformDefault(now: now)
        }
    }
}
