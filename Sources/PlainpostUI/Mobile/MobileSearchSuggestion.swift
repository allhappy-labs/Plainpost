import Foundation
import PlainpostCore

/// One row of the iPhone Search screen's suggestions. There is no query-syntax cheat sheet:
/// `from:` and friends still work, but nothing advertises them.
enum MobileSearchSuggestion: Equatable, Identifiable {
    case askMail(query: String)
    case person(MailSearchSuggestionItem)
    case hasAttachment
    case recent(MailSearchSuggestionItem)

    var id: String {
        switch self {
        case .askMail: "ask-mail"
        case let .person(item): "person-\(item.id)"
        case .hasAttachment: "has-attachment"
        case let .recent(item): "recent-\(item.id)"
        }
    }

    /// "Ask Mail about …" (when a provider can answer and there's a query), up to three
    /// people, "Has attachment" (unless the query has it), then up to five recent searches.
    static func rows(query: String, sections: [MailSearchSuggestionSection], canAskMail: Bool) -> [MobileSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [MobileSearchSuggestion] = []
        if canAskMail, !trimmed.isEmpty { rows.append(.askMail(query: trimmed)) }
        rows += sections.filter { $0.kind == .people }.flatMap(\.items).prefix(3).map(MobileSearchSuggestion.person)
        if !trimmed.lowercased().contains("has:attachment") { rows.append(.hasAttachment) }
        rows += sections.filter { $0.kind == .recent }.flatMap(\.items).prefix(5).map(MobileSearchSuggestion.recent)
        return rows
    }

    /// The query after applying `item`: its insertion replaces the range it names, or the
    /// whole query when it names none.
    static func applying(_ item: MailSearchSuggestionItem, to query: String) -> String {
        guard let range = item.replacementRange else { return item.insertion }
        let source = query as NSString
        let location = min(max(range.location, 0), source.length)
        let length = min(max(range.length, 0), source.length - location)
        return source.replacingCharacters(in: NSRange(location: location, length: length), with: item.insertion)
    }

    static func addingHasAttachment(to query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "has:attachment " : "\(trimmed) has:attachment "
    }
}

/// Where a search snippet's matches are, as string ranges; invalid ranges are dropped.
enum MobileSearchHighlight {
    static func ranges(in snippet: MailSearchSnippet) -> [Range<String.Index>] {
        snippet.highlights.compactMap { Range(NSRange(location: $0.location, length: $0.length), in: snippet.text) }
    }
}
