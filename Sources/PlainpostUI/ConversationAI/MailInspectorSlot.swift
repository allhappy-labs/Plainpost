import Foundation

/// What the Mac's one inspector column shows: Ask Mail or the ✦ conversation pane. Showing one
/// replaces the other, so two inspectors never open side by side.
enum MailInspectorSlot: Equatable, Sendable {
    case askMail
    case conversationAI

    /// The inspector after the button for `requested` is pressed: it closes when it already shows
    /// `requested`; otherwise it opens (or stays open) showing `requested`.
    static func toggled(
        _ requested: MailInspectorSlot,
        isPresented: Bool,
        current: MailInspectorSlot
    ) -> (isPresented: Bool, slot: MailInspectorSlot) {
        if isPresented, current == requested {
            return (false, current)
        }
        return (true, requested)
    }
}
