import Foundation

/// The three lines a mail row shows, already cleaned: a sender name (never a raw
/// `Name <address>` header), a subject that is never blank, and a one-paragraph preview.
struct MobileRowText: Equatable {
    let sender: String
    let subject: String
    let preview: String

    init(sender: String, senderDisplayName: String?, subject: String, preview: String) {
        // Same name source as the macOS/iPad row: with no display name (a bare `From:` address,
        // as Direct IMAP stores it) that row shows a name derived from the address ("Alice"),
        // never the raw address.
        self.sender = MailSenderIdentity(
            sender: sender,
            displayName: MailSenderDisplay.explicitName(displayName: senderDisplayName, address: sender)
        ).displayName
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = trimmedSubject.isEmpty ? "(No subject)" : trimmedSubject
        self.preview = MailPreviewText.display(preview)
    }

    init(row: MessageRowModel) {
        self.init(sender: row.sender, senderDisplayName: row.senderDisplayName, subject: row.subject, preview: row.preview)
    }

    /// What VoiceOver reads for the row, and what UI tests match: "Maria Chen, Plan".
    var accessibilityLabel: String { "\(sender), \(subject)" }

    /// A message header's recipient line: "To: Reader & 2 more", nil when there are none.
    static func recipientLine(to: [String], cc: [String]) -> String? {
        let everyone = to + cc
        guard let first = everyone.first else { return nil }
        let name = MailSenderDisplay.name(displayName: nil, address: first)
        return everyone.count == 1 ? "To: \(name)" : "To: \(name) & \(everyone.count - 1) more"
    }
}
