#if os(iOS)
import SwiftUI

/// Lays tokens out left to right, wrapping when a row is full.
struct MobileFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = Self.size(of: subview, within: width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = Self.size(of: subview, within: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// A subview's ideal size, never wider than a row, so a long address wraps in place
    /// instead of running off the edge.
    private static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width, width.isFinite else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// A To, Cc or Bcc field: address tokens, the email keyboard without capitalisation or
/// autocorrect, and an inline list of people from Contacts and your mail. The first focus
/// is what asks for Contacts access.
struct MobileRecipientField: View {
    let title: String
    @Binding var text: String
    @ObservedObject var suggestions: RecipientSuggestionProvider
    /// The sheet's focus, shared so Return can move it to the next field.
    let focus: FocusState<MobileComposeField?>.Binding
    let field: MobileComposeField
    /// Return, after the typed address became a token: the sheet moves on to the next field.
    let onReturn: () -> Void
    @State private var list = MobileRecipientTokenList(text: "")
    @State private var names: [String: String] = [:]
    @State private var hasPreparedContacts = false

    private var isFocused: Bool { focus.wrappedValue == field }

    private var matches: [RecipientSuggestion] {
        guard isFocused, !list.fragment.isEmpty else { return [] }
        return suggestions.suggestions(matching: list.fragment, excluding: list.excluded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(title):").foregroundStyle(.secondary)
                MobileFlowLayout {
                    ForEach(list.tokens, id: \.self) { token in
                        let isSelected = list.selected == token
                        // A tap selects; the selected token then offers Remove, as in Apple Mail.
                        Button { list.toggleSelection(token) } label: {
                            Text(names[token.lowercased()] ?? MailSenderDisplay.name(displayName: nil, address: token))
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.18), in: Capsule())
                        .accessibilityLabel(token)
                        .accessibilityHint(isSelected ? "Selected. Remove is next to it." : "Selects this recipient")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("compose.token.\(title.lowercased()).\(token)")
                        if isSelected {
                            Button { removeSelected() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(token)")
                            .accessibilityIdentifier("compose.token-remove.\(title.lowercased()).\(token)")
                        }
                    }
                    TextField("", text: fragment)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        .submitLabel(.next)
                        .focused(focus, equals: field)
                        .onSubmit {
                            commitFragment()
                            onReturn()
                        }
                        .frame(minWidth: 120, minHeight: 32)
                        .accessibilityLabel("\(title) recipients")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { suggestion in
                        Button { choose(suggestion) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name ?? suggestion.address)
                                Text("\(suggestion.address) · \(suggestion.source == .contact ? "Contacts" : "from your mail")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(suggestion.name.map { "\($0), \(suggestion.address)" } ?? suggestion.address)
                        Divider()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
            }
        }
        .onAppear { list = .prefilled(text) }
        .onChange(of: text) { _, newValue in
            if newValue != list.text { list = .prefilled(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else {
                // Leaving the field turns a typed address into a token.
                if list.fragment.contains("@") { commitFragment() }
                return
            }
            guard !hasPreparedContacts else { return }
            hasPreparedContacts = true
            Task { await suggestions.prepareContactsIfNeeded() }
        }
    }

    private var fragment: Binding<String> {
        Binding(get: { list.fragment }, set: { typed in
            list.setFragment(typed)
            text = list.text
        })
    }

    private func commitFragment() {
        list.commit(list.fragment)
        text = list.text
    }

    private func choose(_ suggestion: RecipientSuggestion) {
        if let name = suggestion.name { names[suggestion.address.lowercased()] = name }
        list.commit(suggestion.address)
        text = list.text
    }

    private func removeSelected() {
        list.removeSelected()
        text = list.text
    }
}
#endif
