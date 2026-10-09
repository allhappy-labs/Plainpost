import PlainpostCore
import Foundation

struct BenchmarkCorpusItem: Sendable {
    let message: MailboxListMessage
    let expectedCategory: SmartCategory
    let expectedPriority: SmartPriority
    let expectedRequiresAction: Bool
}

enum BenchmarkCorpus {
    static let fixed: [BenchmarkCorpusItem] = {
        let categories = SmartCategory.allCases
        let priorities = SmartPriority.allCases
        return (0..<80).map { index in
            let category = categories[index % categories.count]
            let priority = priorities[index % priorities.count]
            let requiresAction = index.isMultiple(of: 2)
            let variant = index / categories.count
            let content = content(
                category: category,
                variant: variant,
                priority: priority,
                requiresAction: requiresAction
            )
            var preview = content.preview
            if index.isMultiple(of: 7) {
                preview += " — Grüezi, 東京, مرحباً, café ☕️"
            }
            if index.isMultiple(of: 11) {
                preview += " " + String(
                    repeating: "Synthetic context for prompt truncation measurement only. ",
                    count: 45
                )
            }
            let displayName: String?
            if index.isMultiple(of: 9) {
                displayName = ""
            } else if index.isMultiple(of: 10) {
                displayName = nil
            } else {
                displayName = content.displayName
            }
            let message = MailboxListMessage(
                id: MessageID(String(format: "synthetic-%03d", index)),
                threadID: nil,
                from: EmailAddress(content.sender),
                fromDisplayName: displayName,
                subject: content.subject,
                preview: preview,
                smartCategory: .unknown
            )
            return BenchmarkCorpusItem(
                message: message,
                expectedCategory: category,
                expectedPriority: priority,
                expectedRequiresAction: requiresAction
            )
        }
    }()

    static var categoryCounts: [String: Int] {
        Dictionary(grouping: fixed, by: { $0.expectedCategory.rawValue }).mapValues(\.count)
    }

    static var priorityCounts: [String: Int] {
        Dictionary(grouping: fixed, by: { $0.expectedPriority.rawValue }).mapValues(\.count)
    }

    static var actionCounts: [String: Int] {
        Dictionary(grouping: fixed, by: { String($0.expectedRequiresAction) }).mapValues(\.count)
    }

    private struct Content {
        let sender: String
        let displayName: String
        let subject: String
        let preview: String
    }

    private static func content(
        category: SmartCategory,
        variant: Int,
        priority: SmartPriority,
        requiresAction: Bool
    ) -> Content {
        let urgency = switch priority {
        case .high: "Urgent: "
        case .normal: ""
        case .low: "For later: "
        }
        let action = requiresAction
            ? "Please reply or complete the requested step today."
            : "No response or follow-up is needed."

        switch category {
        case .personal:
            return .init(
                sender: "alex.rivera\(variant)@example.test",
                displayName: "Alex Rivera",
                subject: "\(urgency)Dinner plans for Friday",
                preview: "Would 19:30 work for you? \(action)"
            )
        case .notification:
            return .init(
                sender: "no-reply\(variant)@alerts.example.test",
                displayName: "Account Alerts",
                subject: "\(urgency)Workspace notification",
                preview: "A synthetic project setting changed. \(action)"
            )
        case .newsletter:
            return .init(
                sender: "digest\(variant)@newsletter.example.test",
                displayName: "Weekly Research Digest",
                subject: "\(urgency)This week in local-first software",
                preview: "A curated synthetic newsletter with five articles. \(action)"
            )
        case .receipt:
            return .init(
                sender: "receipts\(variant)@shop.example.test",
                displayName: "Example Shop",
                subject: "\(urgency)Receipt for synthetic order #\(1000 + variant)",
                preview: "Order confirmation total CHF 42.00. \(action)"
            )
        case .security:
            return .init(
                sender: "security\(variant)@identity.example.test",
                displayName: "Identity Security",
                subject: "\(urgency)Password alert: new sign-in detected",
                preview: "A new device signed in to the synthetic account. \(action)"
            )
        case .finance:
            return .init(
                sender: "statements\(variant)@bank.example.test",
                displayName: "Example Bank",
                subject: "\(urgency)Monthly statement is ready",
                preview: "Your synthetic balance statement can be reviewed locally. \(action)"
            )
        case .travel:
            return .init(
                sender: "updates\(variant)@rail.example.test",
                displayName: "Example Rail",
                subject: "\(urgency)Travel change: platform and departure time updated",
                preview: "Train EX\(410 + variant) now leaves from platform 7 at 18:24. \(action)"
            )
        case .support:
            return .init(
                sender: "support\(variant)@help.example.test",
                displayName: "Example Support",
                subject: "\(urgency)Support ticket #\(700 + variant) updated",
                preview: "The support agent requested diagnostic confirmation. \(action)"
            )
        case .social:
            return .init(
                sender: "social\(variant)@community.example.test",
                displayName: "Example Community",
                subject: "\(urgency)You were mentioned in a discussion",
                preview: "Taylor mentioned you in a synthetic project thread. \(action)"
            )
        case .system:
            return .init(
                sender: "system\(variant)@host.example.test",
                displayName: "Local System",
                subject: "\(urgency)Nightly backup status",
                preview: "The local synthetic backup completed successfully. \(action)"
            )
        case .invitation:
            return .init(
                sender: "organizer\(variant)@calendar.example.test",
                displayName: "Morgan Organizer",
                subject: "\(urgency)Invitation: design review on Tuesday",
                preview: "You are invited to a 30-minute synthetic meeting. \(action)"
            )
        case .invitationResponse:
            return .init(
                sender: "calendar\(variant)@calendar.example.test",
                displayName: "Calendar Responses",
                subject: "\(urgency)Accepted: design review on Tuesday",
                preview: "A participant accepted your synthetic invitation. \(action)"
            )
        case .unknown:
            return .init(
                sender: "mixed\(variant)@ambiguous.example.test",
                displayName: "Ambiguous Sender",
                subject: "\(urgency)A quick note about the thing",
                preview: "This deliberately ambiguous low-confidence example has no clear category. \(action)"
            )
        }
    }
}
