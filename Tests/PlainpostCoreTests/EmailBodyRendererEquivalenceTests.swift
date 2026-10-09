import Foundation
import XCTest
import PlainpostCore

/// The renderer precompiles its passes and anchors its event-handler patterns at whitespace
/// runs. Neither may change what it produces: these compare it with the original
/// implementation.
final class EmailBodyRendererEquivalenceTests: XCTestCase {
    func testMatchesTheOriginalRendererOnAwkwardMarkup() {
        let samples = [
            "<p>Hello</p>",
            "plain words, no tags at all",
            "<DIV onClick=\"steal()\">x</DIV><IMG SRC=\"https://e.example/a.png\" onerror=go()>",
            "<a href=' javascript:alert(1)'>a</a><a HREF=\"JavaScript:x\">b</a>",
            "<p>*|FNAME|* hi</p>\nline with *|MERGE|* tag\n<!-- note --><br/>end",
            "<td   \t\n   onmouseover = 'x'   >cell</td>" + String(repeating: " ", count: 5_000) + "<b>z</b>",
            String(repeating: "<span>     </span>", count: 2_000) + "<i onload=a>q</i>",
            "<style>p{}</style><script>bad()</script><iframe src=x></iframe><object></object><embed src=y>",
            "<meta http-equiv=\"refresh\" content=\"0\"><base href=\"/\"><link rel=stylesheet href=s.css>",
            "<ul><li>one</li><li>two</li></ul><table><tr><td>a</td></tr></table>&nbsp;&amp;&lt;&gt;&quot;&#39;",
            "   leading on=x and on_click=y and\tonx=\"z\"",
            "<p>&lt;!-- shown --&gt; and &lt;b&gt;</p>\r\n\r\n\r\n<p>after</p>",
        ]
        for sample in samples {
            XCTAssertEqual(EmailBodyRenderer.render(.html(sample)), LegacyRenderer.render(sample), sample)
        }
    }

    /// Set `PP_RENDER_CORPUS` to a directory of `.html` bodies to compare on real mail.
    func testMatchesTheOriginalRendererOnACorpus() throws {
        guard let directory = ProcessInfo.processInfo.environment["PP_RENDER_CORPUS"] else { throw XCTSkip() }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".html") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let html = try String(contentsOfFile: (directory as NSString).appendingPathComponent(file), encoding: .utf8)
            let clock = ContinuousClock()
            var new: RenderedEmailBody?
            var old: RenderedEmailBody?
            let newTime = clock.measure { new = EmailBodyRenderer.render(.html(html)) }
            let oldTime = clock.measure { old = LegacyRenderer.render(html) }
            print("render \(file.prefix(24)) \(html.utf8.count) bytes: \(oldTime) -> \(newTime)")
            XCTAssertEqual(new, old, file)
        }
    }
}

/// The renderer as it was before its passes were precompiled and anchored.
private enum LegacyRenderer {
    static func render(_ html: String) -> RenderedEmailBody {
        let safeHTML = clean(html)
            .replacing(pattern: #"(?is)<script\b[^>]*>.*?</script>"#, with: "")
            .replacing(pattern: #"(?is)<iframe\b[^>]*>.*?</iframe>"#, with: "")
            .replacing(pattern: #"(?is)<object\b[^>]*>.*?</object>"#, with: "")
            .replacing(pattern: #"(?is)<embed\b[^>]*>"#, with: "")
            .replacing(pattern: #"(?is)<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>"#, with: "")
            .replacing(pattern: #"(?is)<base\b[^>]*>"#, with: "")
            .replacing(pattern: #"(?is)<link\b[^>]*>"#, with: "")
            .replacing(pattern: #"(?is)\s+on[a-z]+\s*=\s*(["']).*?\1"#, with: "")
            .replacing(pattern: #"(?is)\s+on[a-z]+\s*=\s*[^\s>]+"#, with: "")
            .replacing(pattern: #"(?is)(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2"#, with: "$1=\"#\"")
        let stripped = safeHTML
            .replacing(pattern: #"(?is)<style\b[^>]*>.*?</style>"#, with: "")
            .replacing(pattern: #"(?is)<img\b[^>]*>"#, with: "")
            .replacing(pattern: #"(?i)</p\s*>"#, with: "\n\n")
            .replacing(pattern: #"(?i)</div\s*>"#, with: "\n")
            .replacing(pattern: #"(?i)</li\s*>"#, with: "\n")
            .replacing(pattern: #"(?i)</tr\s*>"#, with: "\n")
            .replacing(pattern: #"(?i)<br\s*/?>"#, with: "\n")
            .replacing(pattern: #"(?is)<[^>]+>"#, with: "")
        let text = normalize(decode(stripped))
        return RenderedEmailBody(
            kind: .html, safeText: text, safeHTML: safeHTML,
            blockedRemoteImageURLs: EmailBodyRenderer.remoteImageURLs(inHTML: safeHTML)
        )
    }

    private static func clean(_ text: String) -> String {
        text.replacing(pattern: #"(?is)<!--.*?-->"#, with: "")
            .replacing(pattern: #"(?im)^.*\*\|[^|]+\|\*.*$"#, with: "")
            .replacing(pattern: #"(?is)\*\|[^|]+\|\*"#, with: "")
    }

    private static func normalize(_ text: String) -> String {
        var normalized: [String] = []
        var previousWasBlank = true
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            if line.isEmpty {
                if !previousWasBlank { normalized.append("") }
                previousWasBlank = true
            } else {
                normalized.append(line)
                previousWasBlank = false
            }
        }
        while normalized.last?.isEmpty == true { normalized.removeLast() }
        return normalized.joined(separator: "\n")
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

private extension String {
    func replacing(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
