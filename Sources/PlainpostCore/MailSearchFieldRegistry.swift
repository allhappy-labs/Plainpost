import Foundation

public struct MailSearchFieldDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let aliases: [String]
    public let valueSyntax: String
    public let description: String
    public let examples: [String]

    public init(
        name: String,
        aliases: [String] = [],
        valueSyntax: String,
        description: String,
        examples: [String]
    ) {
        self.name = name
        self.aliases = aliases
        self.valueSyntax = valueSyntax
        self.description = description
        self.examples = examples
    }
}

public enum MailSearchFieldRegistry {
    public static let all: [MailSearchFieldDefinition] = [
        .init(
            name: "from",
            valueSyntax: "name, address, or phrase",
            description: "Sender matches the value.",
            examples: ["from:alice", "from:\"Alex Rivera\""]
        ),
        .init(
            name: "to",
            valueSyntax: "name, address, or phrase",
            description: "A To recipient matches.",
            examples: ["to:max"]
        ),
        .init(
            name: "cc",
            valueSyntax: "name, address, or phrase",
            description: "A Cc recipient matches.",
            examples: ["cc:finance"]
        ),
        .init(
            name: "bcc",
            valueSyntax: "name, address, or phrase",
            description: "A Bcc recipient matches.",
            examples: ["bcc:legal"]
        ),
        .init(
            name: "participants",
            aliases: ["participant"],
            valueSyntax: "name, address, or phrase",
            description: "Sender or any recipient matches.",
            examples: ["participants:\"Alex Rivera\""]
        ),
        .init(
            name: "subject",
            valueSyntax: "term, prefix, phrase, or group",
            description: "Search only the subject.",
            examples: ["subject:budget"]
        ),
        .init(
            name: "filename",
            aliases: ["attachment"],
            valueSyntax: "term, prefix, or phrase",
            description: "Search attachment filenames.",
            examples: ["filename:forecast"]
        ),
        .init(
            name: "has",
            valueSyntax: "attachment(s) or document(s)",
            description: "Require the named content type.",
            examples: ["has:attachment", "has:documents"]
        ),
        .init(
            name: "with",
            valueSyntax: "attachment(s) or document(s)",
            description: "Readable alias for has.",
            examples: ["with:attachment", "with:documents"]
        ),
        .init(
            name: "is",
            valueSyntax: "unread, read, flagged, or delegated",
            description: "Filter by message state.",
            examples: ["is:unread"]
        ),
        .init(
            name: "in",
            valueSyntax: "inbox, sent, or trash",
            description: "Filter by canonical mailbox role.",
            examples: ["in:inbox"]
        ),
        .init(
            name: "mailbox",
            valueSyntax: "mailbox name or phrase",
            description: "Filter by local mailbox membership.",
            examples: ["mailbox:\"Project Alpha\""]
        ),
        .init(
            name: "since",
            valueSyntax: "relative duration or date",
            description: "On or after the boundary.",
            examples: ["since:7d"]
        ),
        .init(
            name: "after",
            valueSyntax: "ISO date, today, or yesterday",
            description: "Strict lower date boundary.",
            examples: ["after:2026-07-01"]
        ),
        .init(
            name: "before",
            valueSyntax: "ISO date, today, or yesterday",
            description: "Strict upper date boundary.",
            examples: ["before:2026-08-01"]
        ),
        .init(
            name: "on",
            valueSyntax: "ISO date, today, or yesterday",
            description: "Match one calendar day.",
            examples: ["on:today"]
        ),
        .init(
            name: "date",
            valueSyntax: "start..end",
            description: "Inclusive ISO date range.",
            examples: ["date:2026-07-01..2026-07-18"]
        ),
    ]

    public static let cliGuide = """
    Fields
    \(fieldGuide)

    Query syntax
    - Precedence: parentheses, then NOT, then AND, then OR.
    - Phrases: quote words to require phrase matching; bare terms use query-time prefix matching.
    - Exclusion: use NOT or a leading minus to exclude an expression.
    - Mode: Conversations is the default; request Messages explicitly for individual messages.
    - Limit: defaults to 50 and is clamped to 1...100.
    - Cursor: pass the returned next cursor unchanged to continue keyset paging.
    """

    public static let mcpGuide = """
    Field selection
    Choose the narrowest applicable field from this canonical registry:
    \(fieldGuide)

    Search returns conversations by default. Select messages only when individual messages are needed.
    Follow next_cursor to continue paging; do not request or infer exact result totals.
    """

    public static func canonicalName(for candidate: String) -> String? {
        definition(for: candidate)?.name
    }

    public static func definition(for candidate: String) -> MailSearchFieldDefinition? {
        let folded = candidate.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return all.first { field in
            field.name == folded || field.aliases.contains(folded)
        }
    }

    private static let fieldGuide = all.map { field in
        let aliases = field.aliases.isEmpty ? "" : " (aliases: \(field.aliases.joined(separator: ", ")))"
        let examples = field.examples.joined(separator: ", ")
        return "- \(field.name)\(aliases): \(field.valueSyntax). \(field.description) Examples: \(examples)"
    }.joined(separator: "\n")
}
