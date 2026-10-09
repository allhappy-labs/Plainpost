import Foundation
import PlainpostCore

public enum AskMailListComposer {
    static let peopleCategories: Set<SmartCategory> = [.personal, .support, .invitationResponse]

    public static func sectionStyle(_ category: SmartCategory) -> (title: String, tint: AskMailTint, icon: AskMailIcon) {
        switch category {
        case .notification, .system: ("Notifications", .teal, .bell)
        case .newsletter: ("Newsletters", .purple, .newspaper)
        case .receipt: ("Receipts", .green, .receipt)
        case .finance: ("Finance", .green, .creditCard)
        case .travel: ("Travel", .blue, .airplane)
        case .security: ("Security", .orange, .shield)
        case .social: ("Social", .pink, .person)
        case .invitation: ("Invitations", .orange, .calendar)
        case .personal, .support, .invitationResponse: ("From people", .blue, .person)
        case .unknown: ("Other", .gray, .tray)
        }
    }

    public static func row(_ message: MessageSummary, tag: String?) -> AskMailMessageRow {
        AskMailMessageRow(
            messageID: message.id,
            conversationKey: MailThreading.conversationKey(for: message),
            mailboxPath: message.mailboxPath,
            sender: senderName(message),
            senderAddress: message.from.rawValue,
            subject: message.subject,
            snippet: message.preview,
            sentAt: message.sentAt,
            isUnread: !message.isSeen,
            tag: tag
        )
    }

    /// `categoryCounts` are the real per-category totals for the whole filter (rows are capped);
    /// without them the totals come from the fetched rows.
    public static func answer(plan: AskMailQueryPlan, result: MailFilterResult,
                              categoryCounts: [SmartCategory: Int]? = nil) -> AskMailAnswer {
        let bulk: [AskMailBulkAction] = plan.filter.unreadOnly ? [.markRead, .archive] : [.archive]
        let counts = categoryCounts
            ?? result.messages.reduce(into: [SmartCategory: Int]()) { $0[$1.smartCategory, default: 0] += 1 }
        var blocks: [AskMailBlock] = []
        let text: String
        var suggestions: [String] = []

        switch plan.grouping {
        case .category:
            let people = result.messages.filter { peopleCategories.contains($0.smartCategory) }
            let automated = result.messages.filter { !peopleCategories.contains($0.smartCategory) }
            let groups = Dictionary(grouping: automated) { sectionKey($0.smartCategory) }
            let sectionTotals = counts
                .filter { !peopleCategories.contains($0.key) }
                .reduce(into: [String: Int]()) { $0[sectionKey($1.key), default: 0] += $1.value }
            let sections = groups
                .map { key, messages in
                    section(id: key, category: messages[0].smartCategory, messages: messages,
                            totalCount: max(sectionTotals[key] ?? 0, messages.count))
                }
                .sorted { ($0.totalCount, $1.title) > ($1.totalCount, $0.title) }
            if !sections.isEmpty {
                blocks.append(.messages(AskMailMessageListBlock(
                    id: "automated", title: "Automated", icon: .tray, tint: .teal,
                    sections: sections, bulkActions: bulkActions(bulk, for: sections), rowAction: nil)))
            }
            let peopleTotal = max(counts.filter { peopleCategories.contains($0.key) }.values.reduce(0, +), people.count)
            if !people.isEmpty {
                blocks.append(.messages(AskMailMessageListBlock(
                    id: "people", title: "From people", icon: .person, tint: .blue,
                    sections: [section(id: "people", category: .personal, messages: people, totalCount: peopleTotal)],
                    bulkActions: [], rowAction: .reply)))
            }
            let automatedCount = sections.reduce(0) { $0 + $1.totalCount }
            let total = automatedCount + (people.isEmpty ? 0 : peopleTotal)
            if plan.filter.unreadOnly {
                var sentence = "**\(automatedCount) of your \(total)** unread messages look automated. I grouped them below."
                if !people.isEmpty { sentence += " The **\(peopleTotal) from people** are listed separately." }
                text = sentence
                suggestions = ["Show my unread mail from this week", "Which newsletters do I never open?"]
            } else {
                text = "Found **\(total)** messages."
            }
        case .none:
            let title = plan.searched.first?.label ?? "Messages"
            let style = result.messages.first.map { sectionStyle($0.smartCategory) } ?? (title, .blue, .tray)
            var list = section(id: "all", category: result.messages.first?.smartCategory ?? .unknown,
                               messages: result.messages, totalCount: result.totalCount)
            list.title = title
            blocks.append(.messages(AskMailMessageListBlock(
                id: "results", title: title, icon: style.icon, tint: style.tint,
                sections: [list], bulkActions: bulkActions(bulk, for: [list]), rowAction: nil)))
            text = "Found **\(result.totalCount)** messages."
        }

        return AskMailAnswer(text: text, blocks: blocks, searched: plan.searched, suggestions: suggestions)
    }

    /// No bulk bar unless at least one section has an inbox message to act on.
    private static func bulkActions(_ actions: [AskMailBulkAction], for sections: [AskMailMessageSection]) -> [AskMailBulkAction] {
        sections.contains { !$0.actionMessageIDs.isEmpty } ? actions : []
    }

    public static func noMatch(plan: AskMailQueryPlan, question: String) -> AskMailAnswer {
        var options: [AskMailOption] = []
        if plan.filter.sentAfter != nil || plan.filter.sentBefore != nil {
            options.append(AskMailOption(label: "Search all dates", detail: nil, question: question,
                                         filterOverride: .dropDates))
        }
        if plan.filter.unreadOnly {
            let withoutUnread = question
                .replacingOccurrences(of: "unread", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            options.append(AskMailOption(label: "Include read mail", detail: nil, question: withoutUnread,
                                         filterOverride: .dropUnread))
        }
        // Without filters the search already covered all mail, so offering it again would loop.
        if !plan.filter.isEmpty {
            let term = plan.searchText.isEmpty ? question : plan.searchText
            options.append(AskMailOption(label: "Search all mail for \u{201C}\(term)\u{201D}", detail: nil,
                                         question: term, filterOverride: .searchAllMail))
        }
        return AskMailAnswer(
            text: "I couldn't find any mail that matches.",
            blocks: options.isEmpty
                ? []
                : [.options(AskMailOptionsBlock(id: "widen", title: "Try instead", options: options))],
            searched: plan.searched,
            insufficientEvidence: true
        )
    }

    private static func sectionKey(_ category: SmartCategory) -> String {
        category == .system ? SmartCategory.notification.rawValue : category.rawValue
    }

    private static func section(id: String, category: SmartCategory, messages: [MessageSummary],
                                totalCount: Int) -> AskMailMessageSection {
        let style = sectionStyle(category)
        var names: [String] = []
        for message in messages {
            let name = senderName(message)
            if !names.contains(name) { names.append(name) }
        }
        let summary = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
        return AskMailMessageSection(
            id: id, title: style.title, tint: style.tint, totalCount: totalCount, summary: summary,
            rows: messages.prefix(AskMailLimits.rowsPerSection).map { row($0, tag: nil) },
            // Bulk Archive / Mark read only ever act on inbox mail, never Sent, Archive or Trash.
            actionMessageIDs: Array(messages.lazy
                .filter { MailMailboxFilter.inbox.matches($0.mailboxPath) }
                .prefix(AskMailLimits.actionIDsPerSection).map(\.id))
        )
    }

    static func senderName(_ message: MessageSummary) -> String {
        if let name = message.fromDisplayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return message.from.rawValue
    }
}
