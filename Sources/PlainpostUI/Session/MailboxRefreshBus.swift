import Foundation

/// The one "mailbox content changed, refresh" signal. It replaces
/// PlainpostRootView's `mailboxRevision` state. Writers: message actions,
/// store changes, maintenance success. Reader: the refresh wiring.
@MainActor
final class MailboxRefreshBus: ObservableObject {
    @Published private(set) var revision: Int = 0
    func bump() { revision &+= 1 }
}
