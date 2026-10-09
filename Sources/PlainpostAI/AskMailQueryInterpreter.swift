import Foundation
import PlainpostCore

public enum AskMailIntent: String, Codable, Sendable {
    case list, answer, upcoming, draft
}

public enum AskMailGrouping: String, Codable, Sendable {
    case category, none
}

public struct AskMailQueryPlan: Equatable, Sendable {
    public var intent: AskMailIntent
    public var filter: MailKnowledgeFilter
    /// Free text for full-text search; empty for pure filter lists.
    public var searchText: String
    public var grouping: AskMailGrouping
    public var searched: [AskMailSearchToken]
}

extension AskMailQueryPlan {
    private static let dateTokenLabels: Set<String> = ["Today", "Yesterday", "This week"]

    /// This plan widened for a chosen "Try instead" option.
    public func widened(by override: AskMailFilterOverride, question: String) -> AskMailQueryPlan {
        var plan = self
        switch override {
        case .dropDates:
            plan.filter.sentAfter = nil
            plan.filter.sentBefore = nil
            plan.searched.removeAll { Self.dateTokenLabels.contains($0.label) || $0.label.hasPrefix("Last ") }
        case .dropUnread:
            plan.filter.unreadOnly = false
            plan.searched.removeAll { $0.label == "Unread" }
        case .searchAllMail:
            plan.intent = .answer
            plan.filter = .none
            plan.grouping = .none
            plan.searched = []
            if plan.searchText.isEmpty { plan.searchText = question }
        }
        return plan
    }
}

/// Deterministic reading of a question into filters and an intent. English keywords only in v1;
/// anything unrecognised becomes an `.answer` over full-text search, which is the old behaviour.
public enum AskMailQueryInterpreter {
    private static let categoryWords: [(pattern: String, category: SmartCategory, label: String)] = [
        (#"\bnewsletters?\b"#, .newsletter, "Newsletters"),
        (#"\breceipts?\b"#, .receipt, "Receipts"),
        (#"\bnotifications?\b"#, .notification, "Notifications"),
        (#"\b(flights?|trips?|travel|bookings?)\b"#, .travel, "Travel"),
        (#"\b(invoices?|bills?|payments?)\b"#, .finance, "Finance"),
        (#"\b(invitations?|invites?)\b"#, .invitation, "Invitations"),
        (#"\bsecurity\b"#, .security, "Security"),
    ]

    public static func plan(question: String, now: Date, calendar: Calendar) -> AskMailQueryPlan {
        let text = question.lowercased()
        var filter = MailKnowledgeFilter()
        var searched: [AskMailSearchToken] = []

        if matches(text, #"\bunread\b"#) {
            filter.unreadOnly = true
            searched.append(.init(label: "Unread"))
        }

        for entry in categoryWords where matches(text, entry.pattern) {
            filter.categories.append(entry.category)
            searched.append(.init(label: entry.label))
        }

        if matches(text, #"\b(sent|i sent)\b"#) && !matches(text, #"\bsent me\b"#) {
            filter.mailbox = .sent
            searched.append(.init(label: "Sent"))
        } else if matches(text, #"\barchived?\b"#) {
            filter.mailbox = .archive
            searched.append(.init(label: "Archive"))
        } else if filter.unreadOnly || matches(text, #"\binbox\b"#) {
            filter.mailbox = .inbox
            searched.append(.init(label: "Inbox"))
        }

        if let sender = capture(text, #"\bfrom ([a-z0-9._@+-]+(?: [a-z0-9._@+-]+)?)"#),
           !isDateWord(sender) {
            let name = sender.components(separatedBy: " ").first { !stopAfterFrom.contains($0) } ?? sender
            if !isDateWord(name) {
                filter.senderContains = name
                searched.append(.init(label: "From \(name)"))
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        let hasListVerb = matches(text, #"\b(group|clean|clear|tidy|list|show|find|which|sort)\b"#)
        let upcomingWords = matches(text, #"\b(this week|next week|coming up|upcoming|due|deal with|deadlines?)\b"#)
        // "What's coming up this week?" is an agenda; "unread from Tom this week" is a list with a date filter.
        let isUpcoming = upcomingWords && !hasListVerb && !filter.unreadOnly
            && filter.senderContains == nil && filter.categories.isEmpty
        if matches(text, #"\btoday\b"#) {
            filter.sentAfter = startOfToday
            searched.append(.init(label: "Today"))
        } else if matches(text, #"\byesterday\b"#) {
            filter.sentAfter = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            filter.sentBefore = startOfToday
            searched.append(.init(label: "Yesterday"))
        } else if let days = capture(text, #"\blast (\d{1,3}) days\b"#).flatMap(Int.init) {
            filter.sentAfter = calendar.date(byAdding: .day, value: -days, to: startOfToday)
            searched.append(.init(label: "Last \(days) days"))
        } else if isUpcoming {
            // Deadlines this week usually arrived in the previous three weeks.
            filter.sentAfter = calendar.date(byAdding: .day, value: -21, to: startOfToday)
            searched.append(.init(label: "This week"))
        } else if matches(text, #"\bthis week\b"#) {
            filter.sentAfter = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            searched.append(.init(label: "This week"))
        }

        let intent: AskMailIntent
        if matches(text, #"^(please )?(draft|write|reply|respond)\b|\b(draft|write) (a |an )?(reply|response|email)\b|\breply to\b"#),
           !matches(text, #"^(did|do|does|have|has|had|was|were|is|are)\b"#) {
            intent = .draft
        } else if isUpcoming {
            intent = .upcoming
        } else if hasListVerb
                    || (!filter.isEmpty && !matches(text, #"^(what|why|how|when|did|does|do|is|are)\b"#)) {
            intent = .list
        } else {
            intent = .answer
        }

        let listLike = intent == .list || intent == .upcoming
        return AskMailQueryPlan(
            intent: intent,
            filter: filter,
            searchText: listLike ? "" : question.trimmingCharacters(in: .whitespacesAndNewlines),
            grouping: intent == .list && filter.categories.count != 1 ? .category : .none,
            searched: searched
        )
    }

    private static let stopAfterFrom: Set<String> = ["the", "my", "a", "an"]

    private static func isDateWord(_ value: String) -> Bool {
        ["today", "yesterday", "the", "last", "this", "next"].contains(value.components(separatedBy: " ").first ?? value)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
