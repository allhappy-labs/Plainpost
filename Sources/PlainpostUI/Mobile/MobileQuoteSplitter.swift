import Foundation
import PlainpostCore

/// Splits a plain-text message into what the sender wrote and the quoted history below it,
/// so a conversation can fold the history behind "…".
enum MobileQuoteSplitter {
    struct Parts: Equatable {
        let visible: String
        let quoted: String?
    }

    static func split(_ text: String) -> Parts {
        let lines = text.components(separatedBy: "\n")
        guard let start = quoteStart(in: lines) else {
            return Parts(visible: text, quoted: nil)
        }
        let visible = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return Parts(visible: text, quoted: nil) }
        let quoted = lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(visible: visible, quoted: quoted)
    }

    /// How many lines an "On … wrote:" attribution may wrap over. Mail clients wrap it at about
    /// 72 or 78 columns, so a long name and address take two lines, rarely three.
    static let attributionLineLimit = 3

    /// The first quoted line: a "> " line, or the first line of an "On … wrote:" attribution,
    /// even when the attribution wraps.
    private static func quoteStart(in lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            let trimmed = trim(line)
            if trimmed.hasPrefix(">") { return index }
            guard trimmed.hasSuffix("wrote:") else { continue }
            // Walk back over the wrapped attribution's lines (never across a blank one) to its "On ".
            var first = index
            while first >= 0, index - first < attributionLineLimit, !trim(lines[first]).isEmpty {
                if trim(lines[first]).hasPrefix("On ") { return first }
                first -= 1
            }
        }
        return nil
    }

    private static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MobileQuoteSplitter {
    /// A message body with its quoted history folded away.
    struct Fold: Equatable {
        let body: RenderedEmailBody
        let quoted: String
    }

    /// Folds `original`, a message body as the reader shows it. Nil keeps the message's own
    /// display: HTML, or plain text with no quote to fold.
    static func fold(_ original: RenderedEmailBody) -> Fold? {
        guard original.kind == .plainText else { return nil }
        let parts = split(original.safeText)
        guard let quoted = parts.quoted else { return nil }
        return Fold(
            body: RenderedEmailBody(kind: .plainText, safeText: parts.visible, blockedRemoteImageURLs: original.blockedRemoteImageURLs),
            quoted: quoted
        )
    }

    /// Folds `message`'s body after the same render `ThreadMessageBlock` shows (sharing its
    /// cache), so the fold never brings back markup or whitespace the renderer cleaned.
    static func fold(
        _ message: ThreadMessageModel,
        store: DeferredEmailBodyRenderStore = .shared
    ) async -> Fold? {
        guard let input = message.deferredBody else { return fold(message.renderedBodySnapshot) }
        return fold(await store.render(messageID: message.id, input: input))
    }
}
