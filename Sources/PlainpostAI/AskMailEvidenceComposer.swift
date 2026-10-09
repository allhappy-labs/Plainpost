import Foundation
import PlainpostCore

public enum AskMailEvidenceComposer {
    private static let citationRegex = try! NSRegularExpression(pattern: #"\[(S[0-9]+)\]"#)
    private static let unresolvableRegex = try! NSRegularExpression(pattern: #"\[S[0-9]+\]"#)

    public static func answer(from result: MailboxQuestionAnswer, question: String,
                              searched: [AskMailSearchToken]) -> AskMailAnswer {
        guard !result.insufficientEvidence else {
            return AskMailAnswer(text: result.answer, searched: searched, insufficientEvidence: true)
        }
        let sourcesByID = Dictionary(uniqueKeysWithValues: result.sources.map { ($0.id, $0) })
        let ns = result.answer as NSString
        var numbers: [String: Int] = [:]
        var ordered: [MailKnowledgeSource] = []
        for match in citationRegex.matches(in: result.answer, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            guard numbers[id] == nil, let source = sourcesByID[id] else { continue }
            ordered.append(source)
            numbers[id] = ordered.count
        }
        var text = result.answer
        for (id, number) in numbers { text = text.replacingOccurrences(of: "[\(id)]", with: "[\(number)]") }

        // Remove unresolved citation markers
        text = unresolvableRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // Clean up doubled spaces and space-before-punctuation
        text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ([.!?,;:])", with: "$1", options: .regularExpression)

        let citations = ordered.enumerated().map { AskMailCitation(number: $0.offset + 1, source: $0.element) }
        var blocks: [AskMailBlock] = []
        if !citations.isEmpty {
            let words = keywords(question)
            blocks.append(.quotes(AskMailQuoteBlock(id: "quotes", quotes: citations.map { citation in
                let excerpt = trimmed(citation.source.snippet, limit: 320)
                return AskMailQuote(number: citation.number, source: citation.source, excerpt: excerpt,
                                    highlight: bestSentence(in: excerpt, words: words))
            })))
        }
        return AskMailAnswer(text: text, citations: citations, blocks: blocks, searched: searched)
    }

    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 })
    }

    static func trimmed(_ text: String, limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let prefix = clean.prefix(limit)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func bestSentence(in excerpt: String, words: Set<String>) -> String {
        var best = ""
        var bestScore = 0
        excerpt.enumerateSubstrings(in: excerpt.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            let score = keywords(sentence).intersection(words).count
            if score > bestScore { best = sentence; bestScore = score }
        }
        return excerpt.contains(best) ? best : ""
    }
}
