#if os(iOS)
import SwiftUI

/// The bottom bar's Search, Ask Mail and Compose, shared by Mailboxes, the mailbox list and
/// Conversation, so a fix to one screen's copy isn't missed in the others.
enum MobileMailBottomBar {
    /// Search, then Ask Mail, then `composeTail`: Mailboxes and the mailbox list show all three.
    @ToolbarContentBuilder
    static func searchAskMailCompose(
        openSearch: @escaping () -> Void,
        askMail: @escaping () -> Void,
        compose: @escaping () -> Void,
        allowsMutations: Bool
    ) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(action: openSearch) { Label("Search", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("mailbox.toolbar.search")
        }
        ToolbarItem(placement: .bottomBar) {
            Button(action: askMail) { Label("Ask Mail", systemImage: "sparkles") }
                .accessibilityIdentifier("mailbox.toolbar.ask-mail")
        }
        composeTail(compose: compose, allowsMutations: allowsMutations)
    }

    /// A flexible spacer, then Compose, disabled while mutations aren't allowed: Mailboxes, the
    /// mailbox list and Conversation each show this after their own leading bottom-bar items.
    @ToolbarContentBuilder
    static func composeTail(compose: @escaping () -> Void, allowsMutations: Bool) -> some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action: compose) { Label("Compose", systemImage: "square.and.pencil") }
                .disabled(!allowsMutations)
                .accessibilityIdentifier("mailbox.toolbar.compose")
        }
    }
}
#endif
