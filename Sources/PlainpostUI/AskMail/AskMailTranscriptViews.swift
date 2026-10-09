import Foundation
import PlainpostCore
import SwiftUI

/// Splits answer text into markdown runs and numbered citations (`[1]`).
enum AskMailCitedText {
    enum Segment { case text(AttributedString), citation(Int) }
    /// A wrap unit for `AskMailFlowLayout`: one word (with its trailing space), a citation, a hard
    /// line break (`\n`) or a paragraph break (a run of two or more `\n`).
    enum FlowItem { case word(AttributedString), citation(Int), lineBreak, paragraphBreak }

    static func segments(_ text: String) -> [Segment] {
        let regex = try! NSRegularExpression(pattern: #"\[([0-9]{1,2})\]"#)
        let ns = text as NSString
        var result: [Segment] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result.append(.text(markdown(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))))
            }
            result.append(.citation(Int(ns.substring(with: match.range(at: 1))) ?? 0))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result.append(.text(markdown(ns.substring(from: cursor)))) }
        return result
    }

    static func flowItems(_ text: String) -> [FlowItem] {
        segments(text).flatMap { segment -> [FlowItem] in
            switch segment {
            case .citation(let number): return [.citation(number)]
            case .text(let string): return words(string)
            }
        }
    }

    /// Answer text for copying: markdown removed, citations kept as `[n]`.
    static func plainText(_ text: String) -> String {
        segments(text).map { segment in
            switch segment {
            case .text(let string): String(string.characters)
            case .citation(let number): "[\(number)]"
            }
        }.joined()
    }

    /// Answer text for VoiceOver: citations read as "source n".
    static func spokenText(_ text: String) -> String {
        segments(text).map { segment in
            switch segment {
            case .text(let string): String(string.characters)
            case .citation(let number): "source \(number)"
            }
        }.joined()
    }

    /// Distinct citation numbers in reading order.
    static func citationNumbers(_ text: String) -> [Int] {
        var numbers: [Int] = []
        for case .citation(let number) in segments(text) where !numbers.contains(number) { numbers.append(number) }
        return numbers
    }

    private static func words(_ text: AttributedString) -> [FlowItem] {
        var items: [FlowItem] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text.characters[index]
            let next = text.characters.index(after: index)
            if character == "\n" {
                if start < index { items.append(.word(AttributedString(text[start..<index]))) }
                if case .lineBreak = items.last {
                    items[items.count - 1] = .paragraphBreak
                } else if case .paragraphBreak = items.last {
                    // Further blank lines collapse into the paragraph break.
                } else {
                    items.append(.lineBreak)
                }
                start = next
            } else if character == " " {
                items.append(.word(AttributedString(text[start..<next])))
                start = next
            }
            index = next
        }
        if start < text.endIndex { items.append(.word(AttributedString(text[start..<text.endIndex]))) }
        return items
    }

    private static func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
}

/// Extra space above the line a break starts; `nil` means the subview is not a break.
private struct AskMailLineBreakKey: LayoutValueKey { static let defaultValue: CGFloat? = nil }

/// Wraps subviews left to right, centring each line's items vertically.
struct AskMailFlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var gaps: [CGFloat] = [0]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                // Over-long token (URL, code): let it wrap at the available width.
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let breakGap = subview[AskMailLineBreakKey.self]
            if breakGap != nil || (x > 0 && x + size.width > width) {
                lines.append([])
                gaps.append(breakGap ?? 0)
                x = 0
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        for (line, gap) in zip(lines, gaps) {
            y += gap
            let height = line.map(\.size.height).max() ?? 0
            var lineX: CGFloat = 0
            for item in line {
                frames[item.index] = CGRect(x: lineX, y: y + (height - item.size.height) / 2,
                                            width: item.size.width, height: item.size.height)
                lineX += item.size.width + spacing
            }
            maxWidth = max(maxWidth, lineX - spacing)
            y += height + lineSpacing
        }
        return (frames, CGSize(width: maxWidth, height: max(0, y - lineSpacing)))
    }
}

enum AskMailTypography {
    #if os(iOS)
    static let answer = Font.subheadline
    #else
    static let answer = Font.body
    #endif
}

/// Answer text with inline citation buttons. VoiceOver reads it as one element (citations as
/// "source n" with "Open source n" actions); "Copy answer" copies the plain text with `[n]` markers.
struct AskMailCitedTextView: View {
    let text: String
    let onCitation: (Int) -> Void

    var body: some View {
        let items = AskMailCitedText.flowItems(text)
        AskMailFlowLayout {
            ForEach(items.indices, id: \.self) { index in
                switch items[index] {
                case .word(let word):
                    Text(word).font(AskMailTypography.answer).foregroundStyle(MailDesign.primaryText)
                case .citation(let number):
                    Button { onCitation(number) } label: {
                        Text("\(number)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(MailDesign.secondaryText)
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, 2)
                            .background(AskMailFill.soft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                case .lineBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: AskMailLineBreakKey.self, value: 0)
                case .paragraphBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: AskMailLineBreakKey.self, value: 10)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskMailCitedText.spokenText(text))
        .accessibilityActions {
            ForEach(AskMailCitedText.citationNumbers(text), id: \.self) { number in
                Button("Open source \(number)") { onCitation(number) }
            }
        }
        .contextMenu {
            Button("Copy answer", systemImage: "doc.on.doc") { MailClipboard.copy(AskMailCitedText.plainText(text)) }
        }
    }
}

struct AskMailQuestionBubble: View {
    let question: String

    var body: some View {
        Text(question)
            .font(AskMailTypography.answer)
            .foregroundStyle(MailDesign.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                AskMailFill.soft,
                in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                           bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
            )
            .padding(.leading, 36)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One question and its answer: text, searched tokens, blocks and follow-up suggestions.
struct AskMailTurnView: View {
    let turn: AskMailTurn
    @ObservedObject var viewModel: AskMailViewModel
    let onCitation: (Int) -> Void
    let onChangeSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AskMailQuestionBubble(question: turn.question)
            AskMailCitedTextView(text: turn.answer.text, onCitation: onCitation)
            if !turn.answer.searched.isEmpty {
                searchedRow
            }
            if !turn.answer.blocks.isEmpty {
                VStack(spacing: 10) {
                    ForEach(turn.answer.blocks, id: \.id) { block in
                        AskMailBlockView(turnID: turn.id, block: block, viewModel: viewModel)
                    }
                }
            }
            if !turn.answer.suggestions.isEmpty {
                AskMailFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(turn.answer.suggestions.indices, id: \.self) { index in
                        let suggestion = turn.answer.suggestions[index]
                        Button { Task { await viewModel.ask(suggestion) } } label: {
                            Text(suggestion)
                                .font(.caption)
                                .foregroundStyle(MailDesign.primaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .overlay(Capsule().stroke(MailDesign.stroke))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isWorking)
                    }
                }
            }
        }
    }

    private var searchedRow: some View {
        AskMailFlowLayout(spacing: 4, lineSpacing: 4) {
            Text("Searched")
                .font(.caption)
                .foregroundStyle(MailDesign.tertiaryText)
                .padding(.trailing, 2)
            ForEach(turn.answer.searched.indices, id: \.self) { index in
                Text(turn.answer.searched[index].label)
                    .font(.caption2)
                    .foregroundStyle(MailDesign.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AskMailFill.soft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Button("Change", action: onChangeSearch)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 4)
        }
    }
}

/// Picks the view for one block. Block IDs are turn-scoped so receipts never leak between answers.
struct AskMailBlockView: View {
    let turnID: String
    let block: AskMailBlock
    @ObservedObject var viewModel: AskMailViewModel

    var body: some View {
        switch block {
        case .messages(let list):
            AskMailMessageListBlockView(
                blockID: "\(turnID)/\(list.id)", block: list, viewModel: viewModel, actions: viewModel.actions
            )
        case .card(let card):
            AskMailCardBlockView(turnID: turnID, card: card, viewModel: viewModel)
        case .quotes(let quotes):
            AskMailQuoteBlockView(turnID: turnID, block: quotes) { viewModel.host.openMessage($0) }
        case .draft(let draft):
            AskMailDraftBlockView(
                draft: draft,
                allowsMutations: viewModel.host.allowsMutations(),
                openDraft: { viewModel.host.openDraft($0) }
            )
        case .options(let options):
            AskMailOptionsBlockView(block: options, isWorking: viewModel.isWorking) { option in
                Task { await viewModel.ask(option.question, override: option.filterOverride) }
            }
        }
    }

    static func quoteAnchor(turnID: String, number: Int) -> String { "\(turnID)/quote/\(number)" }
}
