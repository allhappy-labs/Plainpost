import Foundation

/// Readable metadata for one activity row: what stage it's in, which account, and
/// (for finished rows) when it ended. Never surfaces provider/model internals, attempt
/// counters, or the job id.
enum OperationActivityPresentation {
    static func metadata(_ row: OperationActivityRowModel, now: Date) -> String {
        var parts = [row.phase]
        if let email = row.accountEmail {
            parts.append(email)
        }
        if !row.isActive, let ended = row.terminalOccurrenceAt {
            parts.append(RelativeDateTimeFormatter().localizedString(for: ended, relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }
}
