#if os(iOS)
import PlainpostCore
import SwiftUI

/// One piece of sync work the host app runs itself, for the Mailboxes Activity section.
public struct MobileHostActivity: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case syncing, failed }
    public let kind: Kind
    public let accountTitle: String
    public let detail: String?
    public let fraction: Double?
    public var id: String { kind == .failed ? "host-sync-failure" : "host-sync" }

    public init(kind: Kind, accountTitle: String, detail: String? = nil, fraction: Double? = nil) {
        self.kind = kind
        self.accountTitle = accountTitle
        self.detail = detail
        self.fraction = fraction
    }
}

/// What the iPhone shell needs from the app that hosts it: the account menu, a status line
/// and the app's own sync. The app owns one, keeps its published
/// values current and sets its actions; the shell reads it and calls them.
@MainActor
public final class MobileMailEnvironment: ObservableObject {
    /// A status line the host must keep on screen: a held account switch, a released failed
    /// send, a deferred notification open.
    @Published public var banner: AnyView?
    /// A passing line shown above the toolbar until dismissed (a notification whose message
    /// is gone).
    @Published public var notice: String?
    /// The selected account's address, shown read-only in Compose's From row when there's more
    /// than one account. Nil when there's only one (F7).
    @Published public var fromAddress: String?
    /// Why the account is read-only, when it is: the line a mailbox list and Compose show.
    /// Nil while it's writable, or when the host can't say (the shell then says so generically).
    @Published public var readOnlyReason: MobileReadOnlyReason?
    /// The host's own sync, running or failed, listed in the Mailboxes Activity section.
    @Published public var hostActivities: [MobileHostActivity] = []
    /// Pull to refresh: the host's sync, awaited. A sync already running is joined.
    public var syncAction: @MainActor () async -> Void = {}
    /// Retry after the host's sync failed: the sync restarted, even when one is still running
    /// (its wait may never end while offline), and awaited. Nil falls back to `syncAction`.
    public var retryAction: (@MainActor () async -> Void)?
    /// Set by the shell: commits pending grace-period mail actions. The host awaits it before
    /// it replaces the runtime (an account switch), so no archive is lost with the old one.
    public internal(set) var commitPendingActions: @MainActor () async -> Void = {}

    public init() {}

    public func sync() async {
        await syncAction()
    }

    public func retrySync() async {
        await (retryAction ?? syncAction)()
    }
}
#endif
