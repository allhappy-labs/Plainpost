import PlainpostCore
import SwiftUI

/// Numbered quotes from source emails with the relied-on sentence highlighted.
struct AskMailQuoteBlockView: View {
    let turnID: String
    let block: AskMailQuoteBlock
    let open: (MailKnowledgeSource) -> Void

    var body: some View {
        AskMailBlockContainer {
            ForEach(Array(block.quotes.enumerated()), id: \.offset) { index, quote in
                if index > 0 { Divider() }
                quoteRow(quote)
                    .id(AskMailBlockView.quoteAnchor(turnID: turnID, number: quote.number))
            }
        }
    }

    private func quoteRow(_ quote: AskMailQuote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(quote.number)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(MailDesign.secondaryText)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(AskMailFill.soft, in: Capsule())
                MailSenderAvatar(sender: quote.source.sender, displayName: quote.source.sender, size: 16)
                Text(quote.source.sender).font(.caption.weight(.semibold)).foregroundStyle(MailDesign.primaryText).lineLimit(1)
                if let sentAt = quote.source.sentAt {
                    Text("· \(sentAt.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                }
                Spacer(minLength: 4)
                Button("Open") { open(quote.source) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Open \(quote.source.subject)")
            }
            Text(Self.highlighted(quote))
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(MailDesign.stroke).frame(width: 2)
                }
                .padding(.leading, 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static func highlighted(_ quote: AskMailQuote) -> AttributedString {
        var text = AttributedString(quote.excerpt)
        if !quote.highlight.isEmpty, let range = text.range(of: quote.highlight) {
            text[range].backgroundColor = Color.orange.opacity(0.26)
            text[range].foregroundColor = MailDesign.primaryText
        }
        return text
    }
}

/// Editable reply draft. It only opens in the composer; nothing is sent from Ask Mail.
struct AskMailDraftBlockView: View {
    let draft: AskMailDraftBlock
    let allowsMutations: Bool
    let openDraft: (AskMailDraftBlock) -> Void
    @State private var editedBody: String
    @State private var dismissed = false

    init(draft: AskMailDraftBlock, allowsMutations: Bool, openDraft: @escaping (AskMailDraftBlock) -> Void) {
        self.draft = draft
        self.allowsMutations = allowsMutations
        self.openDraft = openDraft
        _editedBody = State(initialValue: draft.body)
    }

    var body: some View {
        if !dismissed {
            AskMailBlockContainer {
                AskMailBlockHeader(icon: .draft, tint: .blue, title: "Draft reply")
                HStack(spacing: 0) {
                    Text("To ").foregroundStyle(MailDesign.secondaryText)
                    Text(draft.recipientName).fontWeight(.semibold).foregroundStyle(MailDesign.primaryText)
                    Text(" · \(draft.subject)").foregroundStyle(MailDesign.secondaryText)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                TextEditor(text: $editedBody)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(6)
                    .mailControlBackground(cornerRadius: 10)
                    .padding(12)
                    .accessibilityLabel("Draft reply to \(draft.recipientName)")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Discard") { dismissed = true }
                        .buttonStyle(.bordered)
                    if allowsMutations {
                        Button("Open in Compose") {
                            var edited = draft
                            edited.body = editedBody
                            openDraft(edited)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

/// "Try instead" choices; each asks a new question.
struct AskMailOptionsBlockView: View {
    let block: AskMailOptionsBlock
    let isWorking: Bool
    let ask: (AskMailOption) -> Void

    var body: some View {
        AskMailBlockContainer {
            Text(block.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MailDesign.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            ForEach(Array(block.options.enumerated()), id: \.offset) { _, option in
                Divider()
                Button { ask(option) } label: {
                    HStack(spacing: 8) {
                        Text(option.label)
                            .font(.subheadline)
                            .foregroundStyle(MailDesign.primaryText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if let detail = option.detail {
                            Text(detail).font(.caption).foregroundStyle(MailDesign.tertiaryText).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }
        }
    }
}
