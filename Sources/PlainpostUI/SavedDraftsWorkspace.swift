#if os(macOS)
import AppKit
import SwiftUI
import PlainpostCore

/// The Mac's Drafts: every account's drafts saved in the composer. Clicking one
/// reopens it; drafts written in other mail apps are in each account's Drafts folder.
struct SavedDraftsWorkspace: View {
    let accounts: [Account]
    let actions: LocalDraftActions
    let openDraft: (ComposerRestoreSnapshot) -> Void
    let openComposer: () -> Void
    @State private var drafts: [Draft] = []
    @State private var failure: String?

    var body: some View {
        Group {
            if drafts.isEmpty {
                MailboxDestinationWorkspace(destination: .drafts, openComposer: openComposer)
            } else {
                List {
                    Section {
                        ForEach(drafts, id: \.id) { draft in
                            Button { openDraft(actions.snapshot(draft)) } label: {
                                SavedDraftListRow(draft: draft, accountLabel: accountLabel(for: draft))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("drafts.saved.\(draft.id.rawValue)")
                            .contextMenu {
                                Button("Open Draft") { openDraft(actions.snapshot(draft)) }
                                Button("Delete Draft", role: .destructive) { discard(draft) }
                            }
                        }
                    } header: {
                        Text("Saved in Plainpost")
                    } footer: {
                        Text("Drafts written in other mail apps are in each account's Drafts folder.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Drafts")
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // A composer window that saved or sent a draft hands focus back here.
            reload()
        }
        .onChange(of: accounts.map(\.id)) { reload() }
        .alert("Couldn't Delete Draft", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func accountLabel(for draft: Draft) -> String? {
        guard accounts.count > 1 else { return nil }
        return accounts.first { $0.id == draft.accountID }?.email.rawValue
    }

    private func reload() {
        drafts = accounts.flatMap { actions.load($0.id) }
    }

    private func discard(_ draft: Draft) {
        do {
            try actions.discard(draft)
        } catch {
            failure = error.localizedDescription
        }
        reload()
    }
}

private struct SavedDraftListRow: View {
    let draft: Draft
    let accountLabel: String?

    var body: some View {
        let summary = SavedDraftSummary(draft)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Draft").font(.callout.weight(.semibold)).foregroundStyle(.red)
                Text(summary.recipients).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if let accountLabel {
                    Text(accountLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(summary.subject).font(.callout).lineLimit(1)
            if !summary.preview.isEmpty {
                Text(summary.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the draft")
    }
}
#endif
