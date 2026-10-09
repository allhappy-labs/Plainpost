#if os(iOS)
import PlainpostCore
import SwiftUI

/// Search across every mailbox: suggestions while typing, then hits as mail rows with the
/// matches highlighted. A hit pushes its conversation; Back returns to the same results.
struct MobileSearchScreen: View {
    let session: MailSession
    let openHit: (MailSearchHit) -> Void
    @ObservedObject private var search: MailSearchViewModel
    @State private var isSearchPresented = true

    init(session: MailSession, openHit: @escaping (MailSearchHit) -> Void) {
        self.session = session
        self.openHit = openHit
        _search = ObservedObject(wrappedValue: session.mailSearch)
    }

    private var suggestions: [MobileSearchSuggestion] {
        MobileSearchSuggestion.rows(query: search.query, sections: search.suggestions, canAskMail: session.search.askMailAction != nil)
    }

    var body: some View {
        List {
            if !suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(suggestions) { suggestionRow($0) }
                }
            }
            if !search.rows.isEmpty {
                Section("Top Hits") {
                    ForEach(search.rows) { hit in
                        Button { openHit(hit) } label: { MobileSearchHitRow(hit: hit) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(MobileSearchHitRow.accessibilityLabel(for: hit))
                            .accessibilityIdentifier("search.result.\(hit.id)")
                            .onAppear { search.loadNextPageIfNeeded(after: hit.id) }
                    }
                }
            }
            status
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search.query, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Search all mail")
        // Keep the title and Back while the field is active, so the results (also after Back
        // from a hit) leave in one tap. Deactivating the field instead would clear the query.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { search.submit() }
        .onAppear { search.prepareInitialSearchSuggestions() }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: MobileSearchSuggestion) -> some View {
        switch suggestion {
        case let .askMail(query):
            Button { session.search.askMailAction?() } label: {
                Label("Ask Mail about “\(query)”", systemImage: "sparkles")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("search.suggestion.ask-mail")
        case let .person(item):
            Button { apply(item, submits: false) } label: {
                HStack {
                    Label(item.title, systemImage: "person.crop.circle")
                    Spacer()
                    Text("from").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
        case .hasAttachment:
            Button { search.query = MobileSearchSuggestion.addingHasAttachment(to: search.query) } label: {
                Label("Has attachment", systemImage: "paperclip")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("search.suggestion.has-attachment")
        case let .recent(item):
            Button { apply(item, submits: true) } label: {
                Label(item.title, systemImage: "clock.arrow.circlepath")
            }
            .frame(minHeight: 44)
        }
    }

    private func apply(_ item: MailSearchSuggestionItem, submits: Bool) {
        guard let current = search.validatedSuggestionForApplication(item) else { return }
        search.query = MobileSearchSuggestion.applying(current, to: search.query)
        if submits { search.submit() }
    }

    @ViewBuilder
    private var status: some View {
        switch search.state {
        case .searching(retainingResults: false):
            ProgressView().frame(maxWidth: .infinity)
        case .empty:
            ContentUnavailableView.search(text: search.query)
        case let .invalid(message):
            Text(message).foregroundStyle(.secondary)
        case .rebuilding:
            Label("Rebuilding the search index…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                Text("Search is unavailable until its index is rebuilt.").foregroundStyle(.secondary)
                if let rebuild = session.search.rebuildAction {
                    Button("Rebuild Index", action: rebuild)
                }
            }
        case .initial, .suggesting, .searching(retainingResults: true), .results:
            EmptyView()
        }
    }
}

/// A search hit laid out like a mailbox row, with its matches highlighted.
private struct MobileSearchHitRow: View {
    let hit: MailSearchHit

    private struct Parts {
        let address: String
        let name: String?
        let subject: String
        let snippet: MailSearchSnippet
        let date: Date?
    }

    /// "Swiss Post, Parcel update", as a mailbox row reads.
    static func accessibilityLabel(for hit: MailSearchHit) -> String {
        let parts = parts(of: hit)
        return MobileRowText(sender: parts.address, senderDisplayName: parts.name, subject: parts.subject, preview: "")
            .accessibilityLabel
    }

    private var parts: Parts { Self.parts(of: hit) }

    private static func parts(of hit: MailSearchHit) -> Parts {
        switch hit {
        case let .conversation(conversation):
            // The best match's sender; `participants` is sorted and mixes in recipients, so
            // it is only the fallback for sources that don't carry the sender.
            Parts(address: conversation.bestMatchSender?.rawValue ?? conversation.participants.first ?? "",
                  name: conversation.bestMatchSenderDisplayName, subject: conversation.subject,
                  snippet: conversation.snippet, date: conversation.latestActivity)
        case let .message(message):
            Parts(address: message.sender.rawValue, name: message.senderDisplayName, subject: message.subject,
                  snippet: message.snippet, date: message.sentAt)
        }
    }

    var body: some View {
        let parts = parts
        let text = MobileRowText(sender: parts.address, senderDisplayName: parts.name, subject: parts.subject, preview: "")
        HStack(alignment: .top, spacing: 10) {
            MailSenderAvatar(sender: MailSenderDisplay.address(parts.address), displayName: parts.name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.sender).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MailTimestampFormatter.inboxLabel(for: parts.date)).font(.footnote).foregroundStyle(.secondary)
                }
                Text(text.subject).font(.subheadline).lineLimit(1)
                Text(highlighted(parts.snippet)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            // Separators start under the text, not under an initials avatar's letters.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func highlighted(_ snippet: MailSearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in MobileSearchHighlight.ranges(in: snippet) {
            guard let attributed = Range(range, in: text) else { continue }
            text[attributed].backgroundColor = Color.yellow.opacity(0.35)
            text[attributed].foregroundColor = Color.primary
        }
        return text
    }
}
#endif
