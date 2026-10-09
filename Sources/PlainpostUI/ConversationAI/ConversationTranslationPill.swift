import Foundation
import NaturalLanguage
import SwiftUI

/// The language a conversation is written in, for the translation pill.
enum ConversationLanguage {
    /// The language most of `texts` is written in, named in `locale` ("German"). Nil when there
    /// is too little text or no language is likely enough, so the pill never names a wrong one.
    static func dominantLanguageName(of texts: [String], locale: Locale = .current) -> String? {
        let sample = String(texts.joined(separator: "\n").prefix(4_000))
        guard sample.filter(\.isLetter).count >= 24 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.key != .undetermined, best.value >= 0.6 else { return nil }
        return locale.localizedString(forLanguageCode: best.key.rawValue)
    }
}

/// Above the first message while the conversation shows translated bodies: what happened, and
/// Show original. While translating it shows the progress instead.
struct ConversationTranslationPill: View {
    let sourceLanguageName: String?
    let progressText: String?
    let showOriginal: () -> Void

    static func label(sourceLanguageName: String?, progressText: String?) -> String {
        if let progressText {
            return "Translating \(progressText)…"
        }
        if let sourceLanguageName {
            return "Translated from \(sourceLanguageName)"
        }
        return "Translated"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "translate")
                .accessibilityHidden(true)
            Text(Self.label(sourceLanguageName: sourceLanguageName, progressText: progressText))
            if progressText == nil {
                Text("·")
                    .accessibilityHidden(true)
                Button("Show original", action: showOriginal)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("conversation.translation-pill.show-original")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.translation-pill")
    }
}
