import Foundation
import PlainpostCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

@MainActor
final class MarkdownComposerController: ObservableObject {
#if os(macOS)
    fileprivate weak var textView: NSTextView?
#else
    fileprivate var applyHandler: ((MarkdownEditorCommand) -> Void)?
#endif

    func apply(_ command: MarkdownEditorCommand) {
#if os(macOS)
        guard let textView else { return }
        let result = MarkdownEditorFormatting.apply(
            command,
            to: textView.string,
            selection: textView.selectedRange()
        )
        textView.string = result.markdown
        textView.setSelectedRange(result.selection)
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
#else
        applyHandler?(command)
#endif
    }
}

enum MarkdownEditorCommand {
    case bold, italic, bulletList, numberedList, link, quote, code
}

struct MarkdownEditorFormattingResult: Equatable {
    let markdown: String
    let selection: NSRange
}

enum MarkdownEditorFormatting {
    static func apply(
        _ command: MarkdownEditorCommand,
        to markdown: String,
        selection: NSRange
    ) -> MarkdownEditorFormattingResult {
        let source = markdown as NSString
        let safeLocation = min(max(selection.location, 0), source.length)
        let safeLength = min(max(selection.length, 0), source.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)
        let selected = source.substring(with: range)

        switch command {
        case .bold:
            return wrap(selected, prefix: "**", suffix: "**", placeholder: "bold text", range: range, source: source)
        case .italic:
            return wrap(selected, prefix: "*", suffix: "*", placeholder: "italic text", range: range, source: source)
        case .code:
            return wrap(selected, prefix: "`", suffix: "`", placeholder: "code", range: range, source: source)
        case .link:
            let label = selected.isEmpty ? "link text" : selected
            let replacement = "[\(label)](https://)"
            return replace(source, range: range, with: replacement, selection: NSRange(location: range.location + label.count + 3, length: 8))
        case .bulletList:
            return toggleLines(prefix: "- ", markdown: source, selection: range)
        case .numberedList:
            return toggleNumberedLines(markdown: source, selection: range)
        case .quote:
            return toggleLines(prefix: "> ", markdown: source, selection: range)
        }
    }

    private static func wrap(
        _ selected: String,
        prefix: String,
        suffix: String,
        placeholder: String,
        range: NSRange,
        source: NSString
    ) -> MarkdownEditorFormattingResult {
        let content = selected.isEmpty ? placeholder : selected
        if selected.hasPrefix(prefix), selected.hasSuffix(suffix), selected.count >= prefix.count + suffix.count {
            let unwrapped = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
            return replace(source, range: range, with: unwrapped, selection: NSRange(location: range.location, length: (unwrapped as NSString).length))
        }
        let replacement = "\(prefix)\(content)\(suffix)"
        return replace(source, range: range, with: replacement, selection: NSRange(location: range.location + prefix.count, length: (content as NSString).length))
    }

    private static func toggleLines(prefix: String, markdown: NSString, selection: NSRange) -> MarkdownEditorFormattingResult {
        let lineRange = markdown.lineRange(for: selection)
        let lines = markdown.substring(with: lineRange).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasPrefix = lines.allSatisfy { $0.hasPrefix(prefix) || $0.isEmpty }
        let replacement = lines.map { line in
            hasPrefix && line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : (line.isEmpty ? line : prefix + line)
        }.joined(separator: "\n")
        return replace(markdown, range: lineRange, with: replacement, selection: NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private static func toggleNumberedLines(markdown: NSString, selection: NSRange) -> MarkdownEditorFormattingResult {
        let lineRange = markdown.lineRange(for: selection)
        let lines = markdown.substring(with: lineRange).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let expression = try? NSRegularExpression(pattern: #"^\d+\.\s+"#)
        let numbered = lines.allSatisfy { line in
            line.isEmpty || expression?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        let replacement = lines.enumerated().map { index, line in
            guard !line.isEmpty else { return line }
            if numbered, let expression {
                return expression.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            }
            return "\(index + 1). \(line)"
        }.joined(separator: "\n")
        return replace(markdown, range: lineRange, with: replacement, selection: NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private static func replace(_ source: NSString, range: NSRange, with replacement: String, selection: NSRange) -> MarkdownEditorFormattingResult {
        MarkdownEditorFormattingResult(
            markdown: source.replacingCharacters(in: range, with: replacement),
            selection: selection
        )
    }
}

struct MarkdownFormattingToolbar: View {
    @ObservedObject var controller: MarkdownComposerController

    var body: some View {
        HStack(spacing: 3) {
            command(.bold, image: "bold", help: "Bold")
            command(.italic, image: "italic", help: "Italic")
            divider
            command(.bulletList, image: "list.bullet", help: "Bullet list")
            command(.numberedList, image: "list.number", help: "Numbered list")
            command(.quote, image: "text.quote", help: "Quote")
            command(.code, image: "chevron.left.forwardslash.chevron.right", help: "Inline code")
            divider
            command(.link, image: "link", help: "Link")
            Spacer()
            Text("Markdown")
                .font(.caption2.weight(.medium))
                .foregroundStyle(MailDesign.tertiaryText)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(MailDesign.control.opacity(0.38), in: RoundedRectangle(cornerRadius: 7))
    }

    private var divider: some View {
        Rectangle().fill(MailDesign.stroke).frame(width: 1, height: 16).padding(.horizontal, 3)
    }

    private func command(_ command: MarkdownEditorCommand, image: String, help: String) -> some View {
        Button { controller.apply(command) } label: {
            Image(systemName: image).frame(width: 25, height: 25)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MailDesign.secondaryText)
        .background(MailDesign.controlHover.opacity(0.001), in: RoundedRectangle(cornerRadius: 5))
        .help(help)
    }
}

#if os(macOS)
struct MarkdownComposerTextView: NSViewRepresentable {
    @Binding var markdown: String
    let controller: MarkdownComposerController
    let placeholder: String
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        let textView = PlaceholderMarkdownTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = NSColor(MailDesign.primaryText)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.placeholder = placeholder
        textView.placeholderColor = NSColor(MailDesign.tertiaryText)
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.string = markdown
        context.coordinator.lastMarkdown = markdown
        controller.textView = textView
        context.coordinator.highlight(textView)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView
        if let placeholderTextView = textView as? PlaceholderMarkdownTextView {
            placeholderTextView.placeholder = placeholder
            placeholderTextView.placeholderColor = NSColor(MailDesign.tertiaryText)
            placeholderTextView.setAccessibilityPlaceholderValue(placeholder)
        }
        guard context.coordinator.lastMarkdown != markdown else { return }
        textView.string = markdown
        context.coordinator.lastMarkdown = markdown
        context.coordinator.highlight(textView)
        textView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownComposerTextView
        var lastMarkdown = ""

        init(parent: MarkdownComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let canonical = MarkdownEmailRenderer.canonicalize(textView.string)
            lastMarkdown = canonical
            if parent.markdown != canonical { parent.markdown = canonical }
            highlight(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            guard !textView.hasMarkedText() else {
                return false
            }
            parent.onCancel()
            return true
        }

        func highlight(_ textView: NSTextView) {
            let fullRange = NSRange(textView.string.startIndex..., in: textView.string)
            textView.textStorage?.setAttributes([
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor(MailDesign.primaryText)
            ], range: fullRange)
            apply(#"\*\*([^*]+)\*\*"#, attributes: [.font: NSFont.boldSystemFont(ofSize: 15)], to: textView)
            apply(#"(?<!\*)\*([^*]+)\*"#, attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 15), toHaveTrait: .italicFontMask)], to: textView)
            apply(#"`([^`]+)`"#, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], to: textView)
            apply(#"\[([^\]]+)\]\((https?://[^\s)]+)\)"#, attributes: [.foregroundColor: NSColor(MailDesign.accentBlue)], to: textView)
        }

        private func apply(_ pattern: String, attributes: [NSAttributedString.Key: Any], to textView: NSTextView) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(textView.string.startIndex..., in: textView.string)
            for match in expression.matches(in: textView.string, range: range) {
                textView.textStorage?.addAttributes(attributes, range: match.range)
            }
        }
    }
}

final class PlaceholderMarkdownTextView: NSTextView {
    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { needsDisplay = true }
    }

    var placeholderDrawingOrigin: NSPoint {
        if let textContainer, let layoutManager {
            layoutManager.ensureLayout(for: textContainer)
        }
        let extraOrigin = layoutManager?.extraLineFragmentUsedRect.origin ?? .zero
        return NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + extraOrigin.x,
            y: textContainerOrigin.y + extraOrigin.y
        )
    }

    var isPlaceholderVisible: Bool {
        string.isEmpty && !placeholder.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPlaceholderVisible else { return }
        (placeholder as NSString).draw(
            at: placeholderDrawingOrigin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 15),
                .foregroundColor: placeholderColor
            ]
        )
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
#else
struct MarkdownComposerTextView: View {
    @Binding var markdown: String
    let controller: MarkdownComposerController
    let placeholder: String
    let onCancel: () -> Void
    /// Lets the host move focus into the editor (Return from Subject on iPhone).
    var isFocused: FocusState<Bool>.Binding?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if markdown.isEmpty {
                Text(placeholder)
                    .foregroundStyle(MailDesign.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            focusable(TextEditor(text: $markdown))
                .scrollContentBackground(.hidden)
                .font(.system(size: 15))
        }
        .onAppear {
            controller.applyHandler = { command in
                let source = markdown as NSString
                let result = MarkdownEditorFormatting.apply(
                    command,
                    to: markdown,
                    selection: NSRange(location: source.length, length: 0)
                )
                markdown = result.markdown
            }
        }
        .onDisappear { controller.applyHandler = nil }
    }

    @ViewBuilder
    private func focusable(_ editor: TextEditor) -> some View {
        if let isFocused {
            editor.focused(isFocused)
        } else {
            editor
        }
    }
}
#endif
