import SwiftUI
import PlainpostCore

struct ApprovalQueueWorkspace: View {
    @ObservedObject var viewModel: ApprovalQueueViewModel
    @Binding var selectedFilter: ApprovalQueueFilter
    @State private var selectedRequestID: String?

    var body: some View {
        NavigationSplitView {
            ApprovalQueueListColumn(
                viewModel: viewModel,
                selectedFilter: $selectedFilter,
                selectedRequestID: $selectedRequestID
            )
        } detail: {
            ApprovalDetailPane(
                item: selectedItem ?? displayItems.first,
                viewModel: viewModel
            )
        }
        .task {
            try? await viewModel.refresh()
            if selectedRequestID == nil || selectedItem == nil {
                selectedRequestID = displayItems.first?.id
            }
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedRequestID = displayItems.first?.id
        }
    }

    private var displayItems: [ApprovalQueueItemModel] {
        viewModel.items.filter { selectedFilter.matches($0) }
    }

    private var selectedItem: ApprovalQueueItemModel? {
        displayItems.first { $0.id == selectedRequestID }
    }
}

struct ApprovalFilterColumn: View {
    @Binding var selectedFilter: ApprovalQueueFilter
    let items: [ApprovalQueueItemModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent approvals")
                    .font(.system(size: 21, weight: .semibold))
            }
            .padding(.bottom, 16)

            ForEach(ApprovalQueueFilter.defaultFilters) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    let isSelected = selectedFilter == filter
                    HStack(spacing: 12) {
                        Image(systemName: filter.systemImage)
                            .foregroundStyle(isSelected ? MailDesign.primaryText : MailDesign.secondaryText)
                            .frame(width: 18)
                        Text(filter.title)
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                        Spacer()
                        if !countLabel(for: filter).isEmpty {
                            Text(countLabel(for: filter))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? MailDesign.primaryText : MailDesign.secondaryText)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(isSelected ? MailDesign.accentBlue.opacity(0.18) : MailDesign.control.opacity(0.58), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(isSelected ? MailDesign.controlHover.opacity(0.86) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(MailDesign.accentBlue)
                                .frame(width: 3, height: 22)
                                .offset(x: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(selectedFilter == filter ? "Selected" : "Not selected"))
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(width: 258)
        .foregroundStyle(MailDesign.primaryText)
        .background(.thinMaterial)
        .background(MailDesign.column.opacity(0.72))
    }

    private func countLabel(for filter: ApprovalQueueFilter) -> String {
        let count = items.filter { filter.matches($0) }.count
        return count > 0 ? "\(count)" : ""
    }
}

struct ApprovalRequestList: View {
    let items: [ApprovalQueueItemModel]
    @Binding var selectedRequestID: String?
    let isWorking: Bool
    let statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MailDesign.secondaryText)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MailDesign.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(MailDesign.control.opacity(0.62), in: Capsule())
            }
            .padding(.horizontal, 16)
            .frame(height: 58)

            ScrollView {
                if items.isEmpty {
                    EmptyState(
                        title: "No approval requests",
                        detail: "Agent send requests matching this filter will appear here for review."
                    )
                    .frame(minHeight: 360)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            ApprovalRequestRow(
                                item: item,
                                selected: selectedRequestID == item.id
                            ) {
                                selectedRequestID = item.id
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 388)
        .background(.thinMaterial)
        .background(MailDesign.column.opacity(0.86))
    }

    private var selectedTitle: String {
        if isWorking {
            return "Sending securely"
        }
        if let statusMessage, statusMessage.localizedCaseInsensitiveContains("failed") {
            return "Needs attention"
        }
        return items.allSatisfy { $0.status.caseInsensitiveCompare("pending") == .orderedSame }
            ? "Needs review"
            : "Requests"
    }
}

struct ApprovalRequestRow: View {
    let item: ApprovalQueueItemModel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                MailAvatar(text: item.agentName.mailInitials, category: .personal, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(ApprovalStatusPresentation.title(for: item.status))
                            .foregroundStyle(statusColor)
                        if item.requiresAuthentication || item.riskFlags.contains(where: { $0.lowercased().contains("risk") }) {
                            Text("High risk")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.weight(.medium))

                    Text(item.subject)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("To: \(item.recipientSummary)")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .lineLimit(1)
                    Text("Requested by \(item.agentName)")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                }
                Spacer()
                if item.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .accessibilityLabel("Has attachments")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? MailDesign.selectionSoft.opacity(0.74) : Color.clear, in: RoundedRectangle(cornerRadius: MailDesign.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.row).stroke(selected ? MailDesign.accentBlue.opacity(0.38) : Color.clear))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(MailDesign.accentBlue)
                        .frame(width: 3, height: 48)
                        .offset(x: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status.lowercased() {
        case "sent":
            .green
        case "failed":
            .red
        case ApprovalStatusPresentation.deliveryUncertain:
            .yellow
        default:
            .orange
        }
    }
}

struct ApprovalDetailPane: View {
    let item: ApprovalQueueItemModel?
    @ObservedObject var viewModel: ApprovalQueueViewModel

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                if let item {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            approvalHeader(item)

                            recipientSummary(item)
                            messagePreview(item)
                            attachmentSummary(item)
                            safetyDisclosure(item)
                        }
                        .frame(width: ApprovalDetailLayout.contentWidth(availableWidth: geometry.size.width), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                    ApprovalReviewBar(
                        item: item,
                        isWorking: viewModel.isWorking,
                        statusMessage: viewModel.statusMessage,
                        approve: {
                            Task {
                                do {
                                    try await viewModel.approveUsingConfiguredCredentials(requestID: item.id)
                                } catch {
                                    // The view model exposes a user-safe failure message.
                                }
                            }
                        },
                        deny: { reason in
                            Task {
                                do {
                                    try await viewModel.deny(requestID: item.id, reason: reason)
                                } catch {
                                    // The view model exposes a user-safe failure message.
                                }
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyState(title: "No approval request selected", detail: "Pending send requests will appear here for review.")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MailDesign.workArea.opacity(0.92))
    }

    private func approvalHeader(_ item: ApprovalQueueItemModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                approvalIdentity(item)
                    .frame(minWidth: 220)
                Spacer(minLength: 12)
                ApprovalStatusBadge(item: item)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 12) {
                approvalIdentity(item)
                ApprovalStatusBadge(item: item)
                    .fixedSize()
            }
        }
    }

    private func approvalIdentity(_ item: ApprovalQueueItemModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.subject)
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Requested by \(item.agentName)")
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func recipientSummary(_ item: ApprovalQueueItemModel) -> some View {
        DetailCard("Sending to") {
            if let details = item.reviewDetails {
                DetailLine("From", details.from)
                DetailLine("To", recipientValue(details.to))
                if !details.cc.isEmpty {
                    DetailLine("Cc", recipientValue(details.cc))
                }
                if !details.bcc.isEmpty {
                    DetailLine("Bcc", "Present")
                }
            } else {
                DetailLine("Recipients", item.recipientSummary.isEmpty ? "Unavailable" : item.recipientSummary)
            }
        }
    }

    @ViewBuilder
    private func messagePreview(_ item: ApprovalQueueItemModel) -> some View {
        DetailCard("Message") {
            if let details = item.reviewDetails {
                Text(details.bodyPlain.nonEmptyApprovalValue ?? "No message body")
                    .font(.callout)
                    .foregroundStyle(MailDesign.primaryText)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else {
                Text("The original message body is unavailable for this request.")
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func attachmentSummary(_ item: ApprovalQueueItemModel) -> some View {
        if item.hasAttachments {
            DetailCard("Attachments") {
                if let details = item.reviewDetails {
                    ForEach(details.attachments) { attachment in
                        AttachmentRow(
                            name: attachment.filename,
                            detail: "\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))"
                        )
                    }
                } else {
                    Text("Attachments are present but their details are unavailable.")
                        .font(.callout)
                        .foregroundStyle(MailDesign.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func safetyDisclosure(_ item: ApprovalQueueItemModel) -> some View {
        if item.requiresAuthentication || !item.riskFlags.isEmpty || item.reviewDetails?.requestReason != nil {
            DisclosureGroup("Review details") {
                VStack(alignment: .leading, spacing: 10) {
                    if item.requiresAuthentication {
                        Label("Local authentication is required before sending.", systemImage: "lock.shield")
                            .foregroundStyle(Color.orange)
                    }
                    if !item.riskFlags.isEmpty {
                        DetailLine("Safety checks", item.riskFlags.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                    }
                    if let details = item.reviewDetails,
                       let reason = details.requestReason?.nonEmptyApprovalValue {
                        DetailLine("Request note", reason)
                        DetailLine("Risk score", "\(details.riskScore) / 100")
                    }
                    DetailLine("Request ID", item.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            }
            .font(.callout.weight(.medium))
            .padding(14)
            .mailPanel(cornerRadius: MailDesign.Radius.control)
        }
    }

    private func recipientValue(_ recipients: [String]) -> String {
        recipients.isEmpty ? "None" : recipients.joined(separator: ", ")
    }
}

struct ApprovalStatusBadge: View {
    let item: ApprovalQueueItemModel

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var title: String {
        if item.requiresAuthentication && item.status.caseInsensitiveCompare("pending") == .orderedSame {
            return "Authentication needed"
        }
        return ApprovalStatusPresentation.title(for: item.status)
    }

    private var symbol: String {
        switch item.status.lowercased() {
        case "sent": "checkmark.circle.fill"
        case "failed": "exclamationmark.circle.fill"
        case ApprovalStatusPresentation.deliveryUncertain: "questionmark.circle.fill"
        default: item.requiresAuthentication ? "lock.shield" : "clock"
        }
    }

    private var tint: Color {
        switch item.status.lowercased() {
        case "sent": MailDesign.accentTeal
        case "failed": Color(hex: 0xFF6B6B)
        case ApprovalStatusPresentation.deliveryUncertain: Color.orange
        default: item.requiresAuthentication ? Color.orange : MailDesign.accentBlue
        }
    }
}

struct ApprovalReviewBar: View {
    let item: ApprovalQueueItemModel
    let isWorking: Bool
    let statusMessage: String?
    let approve: () -> Void
    let deny: (String?) -> Void
    @State private var showsDenialPrompt = false
    @State private var denialReason = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        item: ApprovalQueueItemModel,
        isWorking: Bool = false,
        statusMessage: String? = nil,
        approve: @escaping () -> Void = {},
        deny: @escaping (String?) -> Void = { _ in }
    ) {
        self.item = item
        self.isWorking = isWorking
        self.statusMessage = statusMessage
        self.approve = approve
        self.deny = deny
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(MailDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    compactActions
                }
                .frame(maxWidth: ApprovalDetailLayout.maximumContentWidth)
            } else {
                reviewSummaryAndActions
            }
            #else
            reviewSummaryAndActions
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(MailDesign.stroke).frame(height: 1)
        }
        .alert("Deny send request?", isPresented: $showsDenialPrompt) {
            TextField("Optional reason", text: $denialReason)
            Button("Deny", role: .destructive) {
                deny(denialReason.nonEmptyApprovalValue)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The request will be denied and will not be sent.")
        }
    }

    private var reviewSummaryAndActions: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    reviewSummary
                    Spacer(minLength: 12)
                    regularActions
                }

                VStack(alignment: .leading, spacing: 12) {
                    reviewSummary
                    compactActions
                }
            }
            .frame(maxWidth: ApprovalDetailLayout.maximumContentWidth)
        }
    }

    private var reviewSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: item.requiresAuthentication ? "lock.shield" : "checkmark.seal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 30, height: 30)
                .background(statusTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(reviewTitle)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusMessage ?? reviewDetail)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var regularActions: some View {
        HStack(spacing: 10) {
            workingIndicator

            if isPending {
                denyButton
                approveButton
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var compactActions: some View {
        VStack(spacing: 8) {
            workingIndicator

            if isPending {
                approveButton
                    .frame(maxWidth: .infinity)
                denyButton
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var workingIndicator: some View {
        if isWorking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Approval action in progress")
        }
    }

    private var denyButton: some View {
        Button {
            denialReason = ""
            showsDenialPrompt = true
        } label: {
            Label("Don't Send", systemImage: "xmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.large)
        .disabled(isWorking)
    }

    private var approveButton: some View {
        Button {
            approve()
        } label: {
            Label(item.requiresAuthentication ? "Authenticate & Send" : "Send Now", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
    }

    private var statusTint: Color {
        if !isPending {
            return item.status.caseInsensitiveCompare("sent") == .orderedSame ? MailDesign.accentTeal : MailDesign.secondaryText
        }
        return item.requiresAuthentication ? Color.orange : MailDesign.accentTeal
    }

    private var isPending: Bool {
        item.status.caseInsensitiveCompare("pending") == .orderedSame
    }

    private var reviewTitle: String {
        if isWorking {
            return "Processing request"
        }
        if !isPending {
            return "Request \(item.status.lowercased())"
        }
        return item.requiresAuthentication ? "Local authentication required" : "Ready for review"
    }

    private var reviewDetail: String {
        if !isPending {
            return "This request is no longer awaiting review."
        }
        return item.requiresAuthentication
            ? "Authenticate locally before this message is sent."
            : "Review the message, then send or decline it."
    }
}

enum ApprovalDetailLayout {
    static let maximumContentWidth: CGFloat = 960

    static func contentWidth(availableWidth: CGFloat) -> CGFloat {
        min(maximumContentWidth, max(0, availableWidth - 56))
    }
}

private extension String {
    var nonEmptyApprovalValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
            Text(value)
                .font(.callout)
                .foregroundStyle(MailDesign.primaryText)
        }
    }
}

struct AttachmentRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: name.hasSuffix(".pdf") ? "doc.richtext" : "tablecells")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .background(MailDesign.control, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading) {
                Text(name)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            Spacer()
        }
        .padding(10)
        .background(MailDesign.control.opacity(0.42), in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
    }
}

struct TimelineLine: View {
    let time: String
    let event: String

    init(_ time: String, _ event: String) {
        self.time = time
        self.event = event
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(MailDesign.secondaryText).frame(width: 8, height: 8).padding(.top, 4)
            Text(time)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
                .frame(width: 104, alignment: .leading)
            Text(event)
                .font(.caption)
        }
    }
}

/// How an approval request's status reads in the queue. A possibly-sent
/// request has its own wording: it must not look like a failure to retry.
enum ApprovalStatusPresentation {
    static let deliveryUncertain = SendRequestStatus.deliveryUncertain.rawValue

    static func title(for status: String) -> String {
        switch status.lowercased() {
        case deliveryUncertain: "May have been sent"
        default: status.capitalized
        }
    }
}
