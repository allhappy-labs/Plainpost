import Foundation

/// iPad: whether the ✦ popover is open, and over which reader message. The popover hangs off
/// the detail column rather than the ✦ toolbar button, because that button can overflow into
/// the navigation bar's More menu and leave the popover without an anchor (Ruling 17). The
/// popover closes when the reader shows another message or none, so its open state never
/// outlives the reader it opened over, and the next ✦ tap presents it again.
struct ConversationAIPopoverState: Equatable, Sendable {
    private(set) var isPresented = false
    /// The reader message the popover last opened over.
    private(set) var messageID: String?

    /// ✦ in the reader of `messageID`.
    mutating func open(over messageID: String) {
        self.messageID = messageID
        isPresented = true
    }

    mutating func close() {
        isPresented = false
    }

    /// The reader now shows `messageID`, or nil when no reader shows: another message, or none,
    /// closes the popover.
    mutating func readerDidShow(_ messageID: String?) {
        if messageID != self.messageID {
            isPresented = false
        }
    }
}
