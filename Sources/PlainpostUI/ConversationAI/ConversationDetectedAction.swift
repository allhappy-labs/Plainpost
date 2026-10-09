import Foundation
import PlainpostAI
import PlainpostCore
import PlainpostDB

/// A chip under the summary: add a detected event to Calendar, or a reminder.
struct ConversationDetectedAction: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case calendar
        case reminder
    }

    let kind: Kind
    let title: String
    let card: AskMailCardBlock

    var id: String { "\(card.id)/\(kind.rawValue)" }

    /// The chips for a detected card: "📅 Add “title” date" for a calendar item and
    /// "⏰ Remind me" for a reminder. Items dated before today offer none.
    static func actions(
        from card: AskMailCardBlock?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [ConversationDetectedAction] {
        guard let card else { return [] }
        let today = calendar.startOfDay(for: now)
        var actions: [ConversationDetectedAction] = []
        if let item = card.calendarItem, item.start >= today {
            var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            style.locale = locale
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            actions.append(ConversationDetectedAction(
                kind: .calendar,
                title: "📅 Add “\(item.title)” \(item.start.formatted(style))",
                card: card
            ))
        }
        if let item = card.reminderItem, item.due >= today {
            actions.append(ConversationDetectedAction(kind: .reminder, title: "⏰ Remind me", card: card))
        }
        return actions
    }
}

/// Finds an actionable item (event, booking, bill) in one message.
protocol ConversationActionDetecting: Sendable {
    /// The message's item, or nil when it has none. Throws when detection couldn't run (AI
    /// unavailable or still downloading, a provider error), which isn't "nothing found".
    func detectedCard(messageID: MessageID) async throws -> AskMailCardBlock?
}

/// Detects nothing: previews and tests.
struct NoConversationActionDetector: ConversationActionDetecting {
    func detectedCard(messageID: MessageID) async throws -> AskMailCardBlock? { nil }
}

/// Runs Ask Mail's card extractor on a stored message of the selected account.
final class LocalConversationActionDetector: ConversationActionDetecting, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let selectedAccountID: AccountID?
    private let provider: @Sendable () -> (any AIProvider)?

    /// - Parameter provider: the current AI provider, resolved per call so a provider change in
    ///   Settings applies at once; nil while AI is unavailable.
    init(
        store: SQLiteMailStore,
        selectedAccountID: AccountID?,
        provider: @escaping @Sendable () -> (any AIProvider)?
    ) {
        self.store = store
        self.selectedAccountID = selectedAccountID
        self.provider = provider
    }

    /// Another account's message has nothing to detect. No provider, a message not in the store
    /// or a provider error throws.
    func detectedCard(messageID: MessageID) async throws -> AskMailCardBlock? {
        if let selectedAccountID {
            let owner = try? store.operationAccountID(forMessageID: messageID, explicitAccountID: selectedAccountID)
            guard owner == selectedAccountID else { return nil }
        }
        guard let message = try store.messageSummary(id: messageID) else {
            throw PlainpostError.notFound("Message \(messageID.rawValue)")
        }
        guard let provider = provider() else { throw AIProviderError.unavailable }
        return try await AskMailCardExtractor(provider: provider, now: Date(), calendar: .current).detectCard(for: message)
    }
}
