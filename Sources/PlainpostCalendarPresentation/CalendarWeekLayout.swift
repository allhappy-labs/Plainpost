import Foundation
import PlainpostNodeTransport

package enum CalendarWeekLayout {
    package static func interval(containing date: Date, calendar: Calendar) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    /// Offset-bearing values identify an instant even during a DST fold.
    /// Legacy wall values use their supplied zone, or the display zone for floating times.
    package static func date(_ time: NodeCalendarTime, calendar: Calendar) -> Date? {
        if time.kind == .dateTime {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: time.value) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            if let date = iso.date(from: time.value) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // A date is a civil day in the display calendar, never a provider-zone instant.
        formatter.timeZone = time.kind == .date || time.timezone.isEmpty ? calendar.timeZone : TimeZone(identifier: time.timezone)
        guard formatter.timeZone != nil else { return nil }
        formatter.isLenient = false
        for format in time.kind == .date ? ["yyyy-MM-dd"] : ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: time.value), formatter.string(from: date) == time.value { return date }
        }
        return nil
    }

    package static func placements(events: [NodeCalendarEvent], interval: DateInterval, calendar: Calendar) -> [CalendarEventPlacement] {
        let days = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        guard days.count == 8 else { return [] }
        var result: [CalendarEventPlacement] = []
        for event in events {
            guard let start = date(event.start, calendar: calendar), let end = date(event.end, calendar: calendar), end >= start,
                  start < interval.end, end > interval.start || start == end && start >= interval.start else { continue }
            if event.start.kind == .date {
                let indices = (0..<7).filter { start < days[$0 + 1] && end > days[$0] }
                if let first = indices.first {
                    result.append(.init(eventID: event.id, dayIndex: first, columnIndex: 0, columnCount: 1, startMinute: 0, endMinute: 1440, allDaySpan: indices.count))
                }
            } else {
                for day in 0..<7 where start < days[day + 1] && (end > days[day] || start == end && start >= days[day]) {
                    let clippedStart = max(start, days[day]), clippedEnd = min(end, days[day + 1])
                    let first = minute(clippedStart, calendar: calendar)
                    let last = clippedEnd == days[day + 1] ? 1440 : minute(clippedEnd, calendar: calendar)
                    // A fold can make the end's wall minute precede the start.
                    let displayEnd = min(1440, max(first + 15, last < first ? first + clippedEnd.timeIntervalSince(clippedStart) / 60 : last))
                    result.append(.init(eventID: event.id, dayIndex: day, columnIndex: 0, columnCount: 1, startMinute: first, endMinute: displayEnd, allDaySpan: 0))
                }
            }
        }
        var timed: [CalendarEventPlacement] = []
        for day in 0..<7 {
            let sorted = result.filter { $0.dayIndex == day && $0.allDaySpan == 0 }.sorted {
                if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
                if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
                return $0.eventID < $1.eventID
            }
            var group: [CalendarEventPlacement] = [], columnEnds: [Double] = [], groupEnd: Double = -1
            func flush() {
                timed += group.map { item in var copy = item; copy.columnCount = columnEnds.count; return copy }
                group = []; columnEnds = []; groupEnd = -1
            }
            for var item in sorted {
                if item.startMinute >= groupEnd { flush() }
                let column = columnEnds.firstIndex(where: { $0 <= item.startMinute }) ?? columnEnds.count
                if column == columnEnds.count { columnEnds.append(item.endMinute) } else { columnEnds[column] = item.endMinute }
                item.columnIndex = column; group.append(item); groupEnd = max(groupEnd, item.endMinute)
            }
            flush()
        }
        let allDay = result.filter { $0.allDaySpan > 0 }.sorted { ($0.dayIndex, $0.eventID) < ($1.dayIndex, $1.eventID) }
        return allDay + timed
    }

    package static func minute(_ date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }
}

package struct CalendarEventPlacement: Equatable, Sendable {
    package let eventID: String
    package let dayIndex: Int
    package var columnIndex: Int
    package var columnCount: Int
    package let startMinute: Double
    package let endMinute: Double
    /// Zero for timed events; otherwise the number of visible days (exclusive end).
    package let allDaySpan: Int
}
