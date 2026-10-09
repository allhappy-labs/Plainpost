import Foundation

/// A deliberately small, deterministic Markdown profile for authored mail.
/// HTML is created only when a message is rendered for delivery.
public enum MarkdownEmailRenderer {
    public static func canonicalize(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    public static func plainText(from markdown: String) -> String {
        let canonical = canonicalize(markdown)
        var lines: [String] = []
        var isCodeBlock = false
        for line in canonical.split(separator: "\n", omittingEmptySubsequences: false) {
            var value = String(line)
            if value.hasPrefix("```") {
                isCodeBlock.toggle()
                continue
            }
            if value.hasPrefix("> ") { value.removeFirst(2) }
            value = value.replacingOccurrences(of: "**", with: "")
            value = value.replacingOccurrences(of: "`", with: "")
            value = replaceLinks(in: value) { label, url in "\(label) <\(url)>" }
            value = replacePattern(#"(?<!\*)\*([^*]+)\*"#, in: value, template: "$1")
            lines.append(value)
        }
        return lines.joined(separator: "\n")
    }

    public static func html(from markdown: String) -> String {
        let canonical = canonicalize(markdown)
        var output: [String] = []
        var listKind: ListKind?
        var isCodeBlock = false

        func closeList() {
            if let activeListKind = listKind {
                output.append("</\(activeListKind.rawValue)>")
                listKind = nil
            }
        }

        for rawLine in canonical.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("```") {
                closeList()
                if isCodeBlock { output.append("</code></pre>") } else { output.append("<pre><code>") }
                isCodeBlock.toggle()
                continue
            }
            if isCodeBlock {
                output.append(escape(line))
                continue
            }
            if line.isEmpty {
                closeList()
                continue
            }
            if let item = listItem(line) {
                if listKind != item.kind {
                    closeList()
                    listKind = item.kind
                    output.append("<\(item.kind.rawValue)>")
                }
                output.append("<li>\(inlineHTML(item.text))</li>")
                continue
            }
            closeList()
            if line.hasPrefix("> ") {
                output.append("<blockquote><p>\(inlineHTML(String(line.dropFirst(2))))</p></blockquote>")
            } else {
                output.append("<p>\(inlineHTML(line))</p>")
            }
        }
        closeList()
        if isCodeBlock { output.append("</code></pre>") }
        return output.joined(separator: "\n")
    }

    private enum ListKind: String { case ul, ol }

    private static func listItem(_ line: String) -> (kind: ListKind, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return (.ul, String(line.dropFirst(2)))
        }
        let expression = try? NSRegularExpression(pattern: #"^\d+\.\s+(.+)$"#)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression?.firstMatch(in: line, range: range), let textRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return (.ol, String(line[textRange]))
    }

    private static func inlineHTML(_ text: String) -> String {
        var value = escape(text)
        value = replaceLinks(in: value) { label, url in
            guard allowedLink(url) else { return label }
            return #"<a href="\#(escapeAttribute(url))">\#(label)</a>"#
        }
        value = replacePattern(#"\*\*([^*]+)\*\*"#, in: value, template: "<strong>$1</strong>")
        value = replacePattern(#"(?<!\*)\*([^*]+)\*"#, in: value, template: "<em>$1</em>")
        value = replacePattern(#"`([^`]+)`"#, in: value, template: "<code>$1</code>")
        return value
    }

    private static func replaceLinks(in value: String, replacement: (String, String) -> String) -> String {
        let expression = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#)
        guard let expression else { return value }
        return replacingLinks(expression, in: value, replacement: replacement)
    }

    private static func replacingLinks(
        _ expression: NSRegularExpression,
        in value: String,
        replacement: (String, String) -> String
    ) -> String {
        var result = value
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        for match in matches {
            guard let full = Range(match.range, in: result),
                  let labelRange = Range(match.range(at: 1), in: value),
                  let urlRange = Range(match.range(at: 2), in: value)
            else { continue }
            result.replaceSubrange(full, with: replacement(String(value[labelRange]), String(value[urlRange])))
        }
        return result
    }

    private static func replacePattern(_ pattern: String, in value: String, template: String) -> String {
        let expression = try? NSRegularExpression(pattern: pattern)
        return expression?.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template) ?? value
    }

    private static func allowedLink(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
            return false
        }
        return ["https", "http", "mailto"].contains(scheme)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
