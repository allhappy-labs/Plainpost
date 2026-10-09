import Foundation
import PlainpostCore

public struct AskMailCardExtractor: Sendable {
    private let provider: any AIProvider
    private let now: Date
    private let calendar: Calendar

    public init(provider: any AIProvider, now: Date, calendar: Calendar) {
        self.provider = provider
        self.now = now
        self.calendar = calendar
    }

    public static let schema = AIStructuredSchema.object(name: "MailCard", description: "One actionable item from an email.", properties: [
        .init(name: "relevant", schema: .boolean(description: "False when the email has no booking, bill, event or delivery."), isOptional: false),
        .init(name: "kind", schema: .string(description: nil, choices: AskMailCardKind.allCases.map(\.rawValue)), isOptional: false),
        .init(name: "title", schema: .string(description: "Who or what, e.g. airline and flight number, or the sender of a bill.", choices: nil), isOptional: false),
        .init(name: "hero", schema: .string(description: "The single most important value: a route like ZRH → LHR, an amount like CHF 2,400.00, or a date and time.", choices: nil), isOptional: false),
        .init(name: "subtitle", schema: .string(description: "One short line of context.", choices: nil), isOptional: false),
        .init(name: "fields", schema: .array(.object(name: "Field", description: nil, properties: [
            .init(name: "label", schema: .string(description: nil, choices: nil), isOptional: false),
            .init(name: "value", schema: .string(description: nil, choices: nil), isOptional: false),
        ]), description: "Up to three short facts such as booking code, seat, invoice number.", maxCount: 3), isOptional: false),
        .init(name: "startISO", schema: .string(description: "ISO 8601 local date-time of the event, departure or due date. Empty if none.", choices: nil), isOptional: true),
        .init(name: "endISO", schema: .string(description: "ISO 8601 local end date-time. Empty if none.", choices: nil), isOptional: true),
        .init(name: "location", schema: .string(description: "Place, if any.", choices: nil), isOptional: true),
    ])

    /// The message's card, or nil when it has nothing actionable or the provider failed.
    public func card(for message: MessageSummary) async -> AskMailCardBlock? {
        (try? await detectCard(for: message)) ?? nil
    }

    /// The message's card, or nil when it has nothing actionable. Throws when the provider
    /// fails (unavailable, still downloading, timed out), so a caller can tell "nothing found"
    /// from "couldn't look".
    public func detectCard(for message: MessageSummary) async throws -> AskMailCardBlock? {
        let response = try await provider.generateStructured(
            AIStructuredGenerationRequest(prompt: prompt(message), schema: Self.schema)
        )
        return Self.validate(response.json, message: message, now: now, calendar: calendar)
    }

    private struct Payload: Decodable {
        struct Field: Decodable { var label: String; var value: String }
        var relevant: Bool
        var kind: String
        var title: String
        var hero: String
        var subtitle: String
        var fields: [Field]
        var startISO: String?
        var endISO: String?
        var location: String?
    }

    public static func validate(_ json: Data, message: MessageSummary, now: Date, calendar: Calendar) -> AskMailCardBlock? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json), payload.relevant else { return nil }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hero = payload.hero.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !hero.isEmpty else { return nil }
        let kind = AskMailCardKind(rawValue: payload.kind) ?? .other
        let start = payload.startISO.flatMap { parseDate($0, calendar: calendar, now: now) }
        let end = payload.endISO.flatMap { parseDate($0, calendar: calendar, now: now) }
        let location = payload.location?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        var badge: String?
        // Badges name an upcoming day only: from the start of today to a week ahead, never the past.
        if let start, start >= calendar.startOfDay(for: now), start.timeIntervalSince(now) <= 7 * 86_400 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            let day = formatter.string(from: start)
            badge = kind == .invoice ? "Due \(day)" : day
        }
        let calendarItem = [.flight, .event, .booking].contains(kind) ? start.map {
            AskMailCalendarItem(title: title, start: $0, end: end, location: location, notes: message.subject)
        } : nil
        let reminderItem = kind == .invoice ? start.map {
            AskMailReminderItem(title: "Pay \(title)",
                                due: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) ?? $0,
                                notes: "\(hero) · \(message.subject)")
        } : nil

        return AskMailCardBlock(
            id: "card-\(message.id.rawValue)", kind: kind, title: title, badge: badge, hero: hero,
            subtitle: payload.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: payload.fields
                .map { AskMailCardField(label: $0.label.trimmingCharacters(in: .whitespaces),
                                        value: $0.value.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.label.isEmpty && !$0.value.isEmpty }
                .prefix(3).map { $0 },
            source: AskMailListComposer.row(message, tag: nil).source,
            calendarItem: calendarItem,
            reminderItem: reminderItem
        )
    }

    static func parseDate(_ raw: String, calendar: Calendar, now: Date) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var date = ISO8601DateFormatter().date(from: value)
        if date == nil {
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = format
                if let parsed = formatter.date(from: value) { date = parsed; break }
            }
        }
        guard let date, abs(date.timeIntervalSince(now)) < 2 * 365 * 86_400 else { return nil }
        return date
    }

    private func prompt(_ message: MessageSummary) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd, EEEE"
        let sent = message.sentAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return """
        Read this email and fill the card. Use only facts written in the email. If the email has no \
        booking, bill, event or delivery, set relevant to false.
        Today is \(formatter.string(from: now)).
        From: \(AskMailListComposer.senderName(message))
        Subject: \(message.subject)
        Date: \(sent)
        Body:
        \(String(message.body.prefix(2_400)))
        """
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
