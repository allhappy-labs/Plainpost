import Foundation

/// A failure the iPhone shell shows in an alert, titled for what failed.
struct MobileMailFailure: Equatable {
    let title: String
    let message: String

    /// Archive, delete or a read-state change (from a row, a conversation or Ask Mail).
    static func messageAction(_ message: String) -> MobileMailFailure {
        MobileMailFailure(title: "Unable to update message", message: message)
    }

    /// Marking the opened message read.
    static let markRead = MobileMailFailure(
        title: "Unable to mark as read",
        message: "Plainpost couldn't mark this message as read. Open it again to retry."
    )

    /// Saving an attachment to open it.
    static func attachment(_ detail: String) -> MobileMailFailure {
        MobileMailFailure(title: "Unable to open attachment", message: "Plainpost couldn't open the attachment: \(detail)")
    }
}
