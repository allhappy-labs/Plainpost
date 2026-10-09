import Foundation
import SwiftUI
import PlainpostCore

struct MailSearchInsertionRequest: Equatable {
    let id: UUID
    let text: String
    let replacementRange: MailSearchTextRange?

    init(
        id: UUID,
        text: String,
        replacementRange: MailSearchTextRange? = nil
    ) {
        self.id = id
        self.text = text
        self.replacementRange = replacementRange
    }
}

struct MailSearchTextInsertionResult: Equatable {
    let text: String
    let selectedRange: NSRange
}

enum MailSearchTextInsertion {
    static func apply(
        _ insertedText: String,
        to source: String,
        selectedRange requestedRange: NSRange,
        replacementRange: MailSearchTextRange? = nil
    ) -> MailSearchTextInsertionResult {
        let boundaries = utf16CharacterBoundaries(in: source)
        let sourceLength = boundaries.last ?? 0
        let sourceRange = replacementRange.map {
            NSRange(location: $0.location, length: $0.length)
        } ?? requestedRange
        let requestedLocation = min(max(0, sourceRange.location), sourceLength)
        let requestedEnd = min(
            sourceLength,
            requestedLocation + max(0, sourceRange.length)
        )
        let startOffset = boundaries.last(where: { $0 <= requestedLocation }) ?? 0
        let endOffset: Int
        if sourceRange.length == 0 {
            endOffset = startOffset
        } else {
            endOffset = boundaries.first(where: { $0 >= requestedEnd }) ?? sourceLength
        }

        let startIndex = String.Index(utf16Offset: startOffset, in: source)
        let endIndex = String.Index(utf16Offset: endOffset, in: source)
        let isSyntacticReplacement = replacementRange != nil
        let isTokenRemoval = isSyntacticReplacement && insertedText.isEmpty
        if isTokenRemoval {
            var removalStart = startIndex
            while removalStart > source.startIndex {
                let previous = source.index(before: removalStart)
                guard source[previous].isWhitespace else { break }
                removalStart = previous
            }
            var removalEnd = endIndex
            while removalEnd < source.endIndex, source[removalEnd].isWhitespace {
                removalEnd = source.index(after: removalEnd)
            }
            let separator = removalStart > source.startIndex && removalEnd < source.endIndex
                ? " "
                : ""
            var updated = source
            updated.replaceSubrange(removalStart..<removalEnd, with: separator)
            let caret = source.utf16.distance(from: source.startIndex, to: removalStart)
                + separator.utf16.count
            return MailSearchTextInsertionResult(
                text: updated,
                selectedRange: NSRange(location: caret, length: 0)
            )
        }

        let prefixNeedsSpace = !isSyntacticReplacement && (source[..<startIndex].last.map {
            !$0.isWhitespace
        } ?? false)
        let followingCharacter = endIndex < source.endIndex ? source[endIndex] : nil
        let suffixNeedsSpace = !isSyntacticReplacement
            && (followingCharacter.map { !$0.isWhitespace } ?? !isSyntacticReplacement)
        let insertion = (prefixNeedsSpace ? " " : "")
            + insertedText
            + (suffixNeedsSpace ? " " : "")
        var updated = source
        updated.replaceSubrange(startIndex..<endIndex, with: insertion)

        var caretLocation = startOffset + insertion.utf16.count
        if isSyntacticReplacement,
           let followingCharacter,
           followingCharacter.isWhitespace {
            caretLocation += String(followingCharacter).utf16.count
        }

        return MailSearchTextInsertionResult(
            text: updated,
            selectedRange: NSRange(
                location: caretLocation,
                length: 0
            )
        )
    }

    private static func utf16CharacterBoundaries(in source: String) -> [Int] {
        var boundaries = [0]
        var offset = 0
        for character in source {
            offset += String(character).utf16.count
            boundaries.append(offset)
        }
        return boundaries
    }
}

enum MailSearchKeyboardCommand: Equatable, Sendable {
    case up
    case down
    case cycleForward
    case cycleBackward
    case dismiss
}

#if os(macOS)
import AppKit

struct MailSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusGeneration: Int
    let insertionRequest: MailSearchInsertionRequest?
    let onSubmit: () -> Void
    var onCommand: (MailSearchKeyboardCommand) -> Bool = { _ in false }
    var onSelectionChange: (MailSearchTextRange) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        textField.placeholderString = "Search emails…"
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.font = .systemFont(ofSize: 17, weight: .medium)
        textField.textColor = .labelColor
        textField.setAccessibilityLabel("Search emails")
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }

        if context.coordinator.lastFocusGeneration != focusGeneration {
            context.coordinator.lastFocusGeneration = focusGeneration
            DispatchQueue.main.async { [weak textField] in
                guard let textField else { return }
                textField.window?.makeFirstResponder(textField)
                context.coordinator.configureFieldEditor(for: textField)
            }
        }

        if let insertionRequest,
           context.coordinator.lastHandledInsertionID != insertionRequest.id {
            DispatchQueue.main.async { [weak textField] in
                guard let textField else { return }
                context.coordinator.apply(insertionRequest, to: textField)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MailSearchTextField
        var lastFocusGeneration: Int?
        var lastHandledInsertionID: UUID?
        private weak var observedEditor: NSTextView?

        init(parent: MailSearchTextField) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        var text: String {
            get { parent.text }
            set {
                guard parent.text != newValue else { return }
                parent.text = newValue
            }
        }

        @objc func submit() {
            parent.onSubmit()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            configureFieldEditor(for: textField)
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
            if let editor = textField.currentEditor() {
                reportSelection(editor.selectedRange, in: textField.stringValue)
            }
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCommand(.cycleForward)
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.onCommand(.cycleBackward)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.dismiss)
            default:
                return false
            }
        }

        func configureFieldEditor(for textField: NSTextField) {
            guard let editor = textField.currentEditor() as? NSTextView else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            observeSelection(in: editor)
            reportSelection(editor.selectedRange, in: editor.string)
        }

        func reportSelection(_ range: NSRange, in source: String) {
            let utf16Count = source.utf16.count
            guard range.location >= 0,
                  range.length >= 0,
                  range.location <= utf16Count,
                  range.length <= utf16Count - range.location else { return }
            let composed = (source as NSString).rangeOfComposedCharacterSequences(for: range)
            parent.onSelectionChange(.init(location: composed.location, length: composed.length))
        }

        private func observeSelection(in editor: NSTextView) {
            guard observedEditor !== editor else { return }
            if let observedEditor {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSTextView.didChangeSelectionNotification,
                    object: observedEditor
                )
            }
            observedEditor = editor
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: editor
            )
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            reportSelection(editor.selectedRange, in: editor.string)
        }

        func apply(_ request: MailSearchInsertionRequest, to textField: NSTextField) {
            guard lastHandledInsertionID != request.id else { return }
            textField.window?.makeFirstResponder(textField)
            configureFieldEditor(for: textField)

            let editor = textField.currentEditor()
            let proposedRange = editor?.selectedRange
                ?? NSRange(location: textField.stringValue.utf16.count, length: 0)
            let result = MailSearchTextInsertion.apply(
                request.text,
                to: textField.stringValue,
                selectedRange: proposedRange,
                replacementRange: request.replacementRange
            )

            lastHandledInsertionID = request.id
            textField.stringValue = result.text
            text = result.text
            editor?.selectedRange = result.selectedRange
            reportSelection(result.selectedRange, in: result.text)
        }
    }
}
#else
struct MailSearchTextField: View {
    @Binding var text: String
    let focusGeneration: Int
    let insertionRequest: MailSearchInsertionRequest?
    let onSubmit: () -> Void
    var onCommand: (MailSearchKeyboardCommand) -> Bool = { _ in false }
    var onSelectionChange: (MailSearchTextRange) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool
    @State private var lastHandledInsertionID: UUID?

    var body: some View {
        TextField("Search emails…", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .medium))
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onChange(of: focusGeneration) { _, _ in isFocused = true }
            .onChange(of: isFocused) { _, value in onFocusChange(value) }
            .onChange(of: insertionRequest) { _, request in
                guard let request, request.id != lastHandledInsertionID else { return }
                lastHandledInsertionID = request.id
                let result = MailSearchTextInsertion.apply(
                    request.text,
                    to: text,
                    selectedRange: NSRange(location: text.utf16.count, length: 0),
                    replacementRange: request.replacementRange
                )
                text = result.text
                onSelectionChange(.init(location: result.selectedRange.location, length: 0))
                isFocused = true
            }
            .accessibilityLabel("Search emails")
    }
}
#endif
