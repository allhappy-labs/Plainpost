import XCTest
import AppKit
import SwiftUI
@testable import PlainpostUI

final class MarkdownEditorFormattingTests: XCTestCase {
    func testInlineFormattingSerializesToCanonicalMarkdown() {
        let bold = MarkdownEditorFormatting.apply(.bold, to: "Hello", selection: NSRange(location: 0, length: 5))
        let italic = MarkdownEditorFormatting.apply(.italic, to: "Hello", selection: NSRange(location: 0, length: 5))
        let link = MarkdownEditorFormatting.apply(.link, to: "Docs", selection: NSRange(location: 0, length: 4))
        let code = MarkdownEditorFormatting.apply(.code, to: "value", selection: NSRange(location: 0, length: 5))

        XCTAssertEqual(bold.markdown, "**Hello**")
        XCTAssertEqual(italic.markdown, "*Hello*")
        XCTAssertEqual(link.markdown, "[Docs](https://)")
        XCTAssertEqual(code.markdown, "`value`")
    }

    func testBlockFormattingSerializesListsAndQuotes() {
        let bullets = MarkdownEditorFormatting.apply(.bulletList, to: "One\nTwo", selection: NSRange(location: 0, length: 7))
        let numbers = MarkdownEditorFormatting.apply(.numberedList, to: "One\nTwo", selection: NSRange(location: 0, length: 7))
        let quote = MarkdownEditorFormatting.apply(.quote, to: "One\nTwo", selection: NSRange(location: 0, length: 7))

        XCTAssertEqual(bullets.markdown, "- One\n- Two")
        XCTAssertEqual(numbers.markdown, "1. One\n2. Two")
        XCTAssertEqual(quote.markdown, "> One\n> Two")
    }

    @MainActor
    func testPlaceholderUsesTheTextContainersInsertionOrigin() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: 300))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0
        let textView = PlaceholderMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120), textContainer: container)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.placeholder = "Write your reply..."

        layoutManager.ensureLayout(for: container)
        let extraOrigin = layoutManager.extraLineFragmentUsedRect.origin
        let expectedOrigin = NSPoint(
            x: textView.textContainerOrigin.x + extraOrigin.x,
            y: textView.textContainerOrigin.y + extraOrigin.y
        )

        XCTAssertEqual(textView.placeholderDrawingOrigin, expectedOrigin)
        XCTAssertTrue(textView.isPlaceholderVisible)
        XCTAssertEqual(textView.accessibilityPlaceholderValue(), "Write your reply...")

        textView.string = "Reply"
        XCTAssertFalse(textView.isPlaceholderVisible)
    }

    @MainActor
    func testEscapeCommandInvokesComposerCloseWhileTextViewIsFocused() {
        var didClose = false
        let representable = MarkdownComposerTextView(
            markdown: .constant(""),
            controller: MarkdownComposerController(),
            placeholder: "Write your reply...",
            onCancel: { didClose = true }
        )
        let coordinator = representable.makeCoordinator()

        let handled = coordinator.textView(
            NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(didClose)
    }

    @MainActor
    func testEscapeLeavesMarkedTextForTheInputMethodToCancel() {
        var didClose = false
        let representable = MarkdownComposerTextView(
            markdown: .constant(""),
            controller: MarkdownComposerController(),
            placeholder: "Write your reply...",
            onCancel: { didClose = true }
        )
        let textView = NSTextView()
        textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let handled = representable.makeCoordinator().textView(
            textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertFalse(handled)
        XCTAssertFalse(didClose)
    }
}
