import Foundation

public enum EmailBodyKind: String, Equatable, Sendable {
    case plainText = "plain_text"
    case html
}

public enum EmailBodyInput: Equatable, Sendable {
    case plainText(String)
    case html(String)
}

public struct RenderedEmailBody: Equatable, Sendable {
    public let kind: EmailBodyKind
    public let safeText: String
    public let safeHTML: String?
    public let blockedRemoteImageURLs: [String]

    public init(kind: EmailBodyKind, safeText: String, safeHTML: String? = nil, blockedRemoteImageURLs: [String]) {
        self.kind = kind
        self.safeText = safeText
        self.safeHTML = safeHTML
        self.blockedRemoteImageURLs = blockedRemoteImageURLs
    }
}

public enum EmailBodyRenderer {
    private static let remoteImageRegex = try? NSRegularExpression(
        pattern: #"(?is)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#
    )

    public static func render(_ input: EmailBodyInput) -> RenderedEmailBody {
        switch input {
        case let .plainText(text):
            return RenderedEmailBody(
                kind: .plainText,
                safeText: text.cleaningGeneratedMarkup().normalizingDisplayWhitespace(),
                safeHTML: nil,
                blockedRemoteImageURLs: []
            )
        case let .html(html):
            return renderHTML(html)
        }
    }

    private static func renderHTML(_ html: String) -> RenderedEmailBody {
        let safeHTML = html.cleaningGeneratedMarkup().applying(Rule.unsafeMarkup)
        let blockedURLs = remoteImageURLs(in: safeHTML)
        let stripped = safeHTML
            .applying(Rule.textOnly)
            .decodingMinimalHTMLEntities()
            .normalizingDisplayWhitespace()

        return RenderedEmailBody(
            kind: .html,
            safeText: stripped,
            safeHTML: safeHTML,
            blockedRemoteImageURLs: blockedURLs
        )
    }

    public static func remoteImageURLs(inHTML html: String) -> [String] {
        remoteImageURLs(in: html)
    }

    private static func remoteImageURLs(in html: String) -> [String] {
        guard let regex = remoteImageRegex else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            let value = String(html[valueRange])
            return value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") ? value : nil
        }
    }
}

/// One rewrite of an email body, compiled once rather than on every render. `literal` is
/// letter-free text every match contains; a body without it skips the pass.
private struct Rule: @unchecked Sendable {
    let regex: NSRegularExpression?
    let template: String
    let literal: [UInt8]?

    init(_ pattern: String, _ template: String = "", literal: String? = nil) {
        regex = try? NSRegularExpression(pattern: pattern)
        self.template = template
        self.literal = literal.map { Array($0.utf8) }
    }

    /// Comments and merge tags. Most mail has no merge tag, and the line pattern is one of
    /// the slowest passes on a large body.
    static let generatedMarkup = [
        Rule(#"(?is)<!--.*?-->"#, literal: "<!--"),
        Rule(#"(?im)^.*\*\|[^|]+\|\*.*$"#, literal: "*|"),
        Rule(#"(?is)\*\|[^|]+\|\*"#, literal: "*|"),
    ]

    /// Scripts, frames, plugins, refreshes, base and link elements, event handlers and
    /// `javascript:` URLs. The handler patterns start only at the beginning of a whitespace
    /// run: the leftmost match always does, and retrying from inside a long run made those
    /// passes quadratic.
    static let unsafeMarkup = [
        Rule(#"(?is)<script\b[^>]*>.*?</script>"#),
        Rule(#"(?is)<iframe\b[^>]*>.*?</iframe>"#),
        Rule(#"(?is)<object\b[^>]*>.*?</object>"#),
        Rule(#"(?is)<embed\b[^>]*>"#),
        Rule(#"(?is)<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>"#),
        Rule(#"(?is)<base\b[^>]*>"#),
        Rule(#"(?is)<link\b[^>]*>"#),
        Rule(#"(?is)(?<!\s)\s+on[a-z]+\s*=\s*(["']).*?\1"#),
        Rule(#"(?is)(?<!\s)\s+on[a-z]+\s*=\s*[^\s>]+"#),
        Rule(#"(?is)(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2"#, "$1=\"#\""),
    ]

    /// Turns sanitized HTML into its text: styles and images go, block ends become line
    /// breaks, then every remaining tag goes.
    static let textOnly = [
        Rule(#"(?is)<style\b[^>]*>.*?</style>"#),
        Rule(#"(?is)<img\b[^>]*>"#),
        Rule(#"(?i)</p\s*>"#, "\n\n"),
        Rule(#"(?i)</div\s*>"#, "\n"),
        Rule(#"(?i)</li\s*>"#, "\n"),
        Rule(#"(?i)</tr\s*>"#, "\n"),
        Rule(#"(?i)<br\s*/?>"#, "\n"),
        Rule(#"(?is)<[^>]+>"#),
    ]
}

private extension String {
    func cleaningGeneratedMarkup() -> String {
        applying(Rule.generatedMarkup)
    }

    func applying(_ rules: [Rule]) -> String {
        rules.reduce(self) { text, rule in
            guard let regex = rule.regex else { return text }
            if let literal = rule.literal, !text.containsBytes(literal) { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
        }
    }

    func containsBytes(_ needle: [UInt8]) -> Bool {
        var text = self
        return text.withUTF8 { bytes in
            guard let first = needle.first, bytes.count >= needle.count else { return false }
            var index = 0
            let last = bytes.count - needle.count
            while index <= last {
                if bytes[index] == first,
                   needle.indices.allSatisfy({ bytes[index + $0] == needle[$0] }) {
                    return true
                }
                index += 1
            }
            return false
        }
    }

    func decodingMinimalHTMLEntities() -> String {
        replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    func normalizingDisplayWhitespace() -> String {
        let lines = replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }

        var normalized: [String] = []
        var previousWasBlank = true
        for line in lines {
            if line.isEmpty {
                if !previousWasBlank {
                    normalized.append("")
                }
                previousWasBlank = true
            } else {
                normalized.append(line)
                previousWasBlank = false
            }
        }
        while normalized.last?.isEmpty == true {
            normalized.removeLast()
        }
        return normalized.joined(separator: "\n")
    }
}
