import Foundation
import SwiftUI
import PlainpostCore
import PlainpostOperations

public extension MailLabelDefinition {
    static let global = previewDefinition(
        id: "global",
        title: "Receipts",
        scope: .allAccounts
    )
    static let accountA = previewDefinition(
        id: "account-a",
        title: "Work Travel",
        scope: .account(AccountID("a"))
    )
    static let accountB = previewDefinition(
        id: "account-b",
        title: "Personal Travel",
        scope: .account(AccountID("b"))
    )
    static let globalSmart = previewDefinition(
        id: "global-smart",
        title: "Finance",
        description: "Invoices, receipts, bank notices, and payment confirmations.",
        isSmartInboxEnabled: true,
        scope: .allAccounts
    )
    static let globalManualOnly = previewDefinition(
        id: "global-manual",
        title: "Reference",
        scope: .allAccounts
    )
    static let accountASmart = previewDefinition(
        id: "account-a-smart",
        title: "Client Work",
        description: "Messages about active client projects and deliverables.",
        isSmartInboxEnabled: true,
        scope: .account(AccountID("a"))
    )

    private static func previewDefinition(
        id: String,
        title: String,
        description: String = "",
        isSmartInboxEnabled: Bool = false,
        scope: MailLabelScope
    ) -> MailLabelDefinition {
        try! MailLabelDefinition.validated(
            id: id,
            title: title,
            description: description,
            isSmartInboxEnabled: isSmartInboxEnabled,
            scope: scope,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }
}

@MainActor
public final class SmartInboxRunProbe {
    public private(set) var requests: [PlainpostSmartInboxRunRequest] = []
    private let result: MailLabelRunProgress

    public init(result: MailLabelRunProgress = .init(updated: 0, unchanged: 0, failed: 0)) {
        self.result = result
    }

    public func run(_ request: PlainpostSmartInboxRunRequest) async throws -> MailLabelRunProgress {
        requests.append(request)
        return result
    }
}

public extension MailLabelsViewModel {
    @MainActor
    static func fixture(
        labels: [MailLabelDefinition],
        runProbe: SmartInboxRunProbe = SmartInboxRunProbe(),
        deletionPreview: MailLabelDeletionPreview? = nil
    ) -> MailLabelsViewModel {
        let work = Account(
            id: AccountID("a"),
            displayName: "Work",
            email: EmailAddress("me@work.example"),
            imapHost: "imap.work.example",
            smtpHost: "smtp.work.example"
        )
        let personal = Account(
            id: AccountID("b"),
            displayName: "Personal",
            email: EmailAddress("me@personal.example"),
            imapHost: "imap.personal.example",
            smtpHost: "smtp.personal.example"
        )
        return MailLabelsViewModel(
            accounts: [work, personal],
            labels: labels,
            deletionPreview: deletionPreview,
            runReclassification: { request in
                try await runProbe.run(request)
            }
        )
    }

    @MainActor
    static func preview() -> MailLabelsViewModel {
        preview(state: .standard)
    }

    @_spi(DesignPreview)
    @MainActor
    static func preview(state: MailLabelsDesignPreviewState) -> MailLabelsViewModel {
        let labels: [MailLabelDefinition] = switch state {
        case .empty, .emptyAdd:
            []
        case .descriptionValidation:
            [.globalManualOnly]
        default:
            [.globalSmart, .globalManualOnly, .accountASmart]
        }
        let model = fixture(
            labels: labels,
            deletionPreview: MailLabelDeletionPreview(
                labelID: MailLabelDefinition.globalSmart.id,
                scope: MailLabelDefinition.globalSmart.scope,
                affectedMessageCount: 12,
                affectedRuleCount: 2
            )
        )
        model.configureDesignPreview(state)
        return model
    }
}

@_spi(DesignPreview)
public struct MessageLabelsSubmenuDesignPreview: View {
    public static let items: [MessageLabelMenuItem] = [
        item(
            id: "preview-user",
            title: "Added manually",
            sources: [.user]
        ),
        item(
            id: "preview-rule",
            title: "Added by rule",
            sources: [.rule(ruleID: "travel-rule")]
        ),
        item(
            id: "preview-smart-inbox",
            title: "Added by Smart Inbox",
            sources: [.smartInbox]
        ),
        item(
            id: "preview-combined",
            title: "Combined ownership",
            sources: [.user, .rule(ruleID: "travel-rule"), .smartInbox]
        ),
        item(
            id: "preview-excluded",
            title: "Excluded from Smart Inbox",
            sources: [],
            isExcluded: true
        ),
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Labels", systemImage: "tag")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ForEach(Self.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.isEffective ? "checkmark" : "tag")
                        .frame(width: 16)
                        .foregroundStyle(item.isEffective ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout)
                        Text(detail(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.title)
                .accessibilityValue(detail(for: item))
            }
        }
        .frame(width: 330, alignment: .topLeading)
        .background(MailDesign.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MailDesign.stroke)
        )
        .padding(24)
    }

    private func detail(for item: MessageLabelMenuItem) -> String {
        if item.isExcluded {
            return "Smart Inbox will not restore this label"
        }
        return item.ownershipHelp ?? "Available to add manually"
    }

    private static func item(
        id: String,
        title: String,
        sources: Set<MailLabelAssignmentSource>,
        isExcluded: Bool = false
    ) -> MessageLabelMenuItem {
        let label = try! MailLabelDefinition.validated(
            id: id,
            title: title,
            description: "\(title) preview",
            isSmartInboxEnabled: false,
            scope: .allAccounts,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        return MessageLabelMenuItem(
            label: label,
            sources: sources,
            isExcluded: isExcluded,
            ruleNames: ["travel-rule": "Travel rule"]
        )
    }
}
