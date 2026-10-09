#if os(iOS)
import SwiftUI

/// Agent Approvals on iPhone: it opens on the list; a request pushes its review.
struct MobileApprovalsScreen: View {
    @ObservedObject var approvalQueue: ApprovalQueueViewModel
    @State private var filter: ApprovalQueueFilter = .pending

    private var items: [ApprovalQueueItemModel] {
        approvalQueue.items.filter { filter.matches($0) }
    }

    var body: some View {
        List {
            if let refreshFailure = approvalQueue.refreshFailure {
                // Pull to refresh failed: say so, or the stale list looks current.
                Label(refreshFailure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .accessibilityIdentifier("approvals.refresh-failure")
            }
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(ApprovalQueueFilter.defaultFilters) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No requests",
                        systemImage: "checkmark.seal",
                        description: Text("Messages your agents want to send wait here for your review.")
                    )
                }
                ForEach(items) { item in
                    NavigationLink(value: MobileRoute.approval(requestID: item.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.subject).font(.headline)
                            Text(item.recipientSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(item.agentName) · \(item.status.capitalized)").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Agent Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await approvalQueue.refresh() }
    }
}

struct MobileApprovalDetailScreen: View {
    @ObservedObject var approvalQueue: ApprovalQueueViewModel
    let requestID: String

    var body: some View {
        ApprovalDetailPane(item: approvalQueue.items.first { $0.id == requestID }, viewModel: approvalQueue)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
