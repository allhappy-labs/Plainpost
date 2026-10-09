import PlainpostAccountProtocol
import PlainpostCore

/// Where Settings navigation can point: a static section, a specific mail account, or a
/// specific Node mailbox.
public enum PlainpostSettingsDestination: Hashable, Sendable {
    case section(PlainpostSettingsSection)
    case account(AccountID)
    case nodeAccount(LogicalMailboxID)
}
