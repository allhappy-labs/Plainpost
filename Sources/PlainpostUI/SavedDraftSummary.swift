import Foundation
import PlainpostCore

/// How a draft saved in the composer reads in a Drafts list: who it's to,
/// its subject, and its first authored line (never a quoted one).
struct SavedDraftSummary: Equatable {
    let recipients: String
    let subject: String
    let preview: String

    init(_ draft: Draft) {
        let names = (draft.to + draft.cc).map(\.rawValue)
        recipients = names.isEmpty ? "No Recipients" : names.joined(separator: ", ")
        let trimmed = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        subject = trimmed.isEmpty ? "No Subject" : trimmed
        preview = draft.bodyPlain
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix(">") } ?? ""
    }
}
