import Foundation

/// The one rule for list previews: every whitespace run (spaces, tabs,
/// line and paragraph breaks, non-breaking spaces) becomes a single space.
public enum MailPreviewNormalizer {
    public static func normalized(_ text: String, limit: Int = 500) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(max(0, limit)))
    }
}
