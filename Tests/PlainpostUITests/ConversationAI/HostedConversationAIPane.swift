import AppKit
import SwiftUI
import XCTest
@testable import PlainpostUI

/// A `ConversationAIPane` hosted in a real window, found through its accessibility tree, so a
/// test sees what the person sees and presses its buttons.
@MainActor
final class HostedConversationAIPane {
    let window: NSWindow
    let host: NSView

    init(model: ConversationAIPaneModel) {
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        host = NSHostingView(rootView: ConversationAIPane(
            model: model, translationLanguage: TranslationLanguageOption(id: "en", localizedName: "English"),
            readOnlyReason: nil, dismissAfterTranslate: nil, openCompose: { _ in }
        ))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    /// The element with `identifier`, polling up to `tries` times while SwiftUI updates; nil if
    /// it never appears.
    func element(_ identifier: String, tries: Int = 100) async -> NSObject? {
        for _ in 0..<tries {
            host.layoutSubtreeIfNeeded()
            if let element = Self.tree(window).first(where: {
                Self.value($0, "accessibilityIdentifier") as? String == identifier
            }) {
                return element
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The text `element` shows, as VoiceOver reads it: a static text's value, or a label.
    func text(_ element: NSObject) -> String? {
        let value = Self.value(element, "accessibilityValue")
        let text = (value as? String) ?? (value as? NSAttributedString)?.string
        return text ?? Self.value(element, "accessibilityLabel") as? String
    }

    func press(_ element: NSObject) -> Bool {
        if let control = element as? any NSAccessibilityProtocol { return control.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector)
    }

    private static func tree(_ value: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 30, let element = value as? NSObject else { return [] }
        let children = Self.value(element, "accessibilityChildren") as? [Any] ?? []
        return [element] + children.flatMap { tree($0, depth: depth + 1) }
    }

    /// SwiftUI's virtual elements implement the informal NSObject accessibility API; native
    /// controls implement NSAccessibilityProtocol. Both answer these selectors.
    private static func value(_ object: NSObject, _ selectorName: String) -> Any? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}
