import XCTest
@testable import PlainpostUI

@MainActor
final class ConversationTranslationPillTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testDetectsTheBodiesLanguage() {
        let german = """
        Sehr geehrter Herr Vdovenko, die Frist für die Einreichung Ihrer Steuererklärung 2025 \
        endet am 31. März. Bitte reichen Sie Ihre Unterlagen über ZHprivateTax ein.
        """
        XCTAssertEqual(ConversationLanguage.dominantLanguageName(of: [german], locale: english), "German")
        let englishText = "Good catch, updated. See you Thursday at 10:00 in the Harbour room. Maria"
        XCTAssertEqual(ConversationLanguage.dominantLanguageName(of: [englishText], locale: english), "English")
    }

    /// Review Focus 4: too little text names no language, so the pill falls back.
    func testShortOrEmptyTextHasNoLanguage() {
        XCTAssertNil(ConversationLanguage.dominantLanguageName(of: ["Ok, thanks"], locale: english))
        XCTAssertNil(ConversationLanguage.dominantLanguageName(of: [""], locale: english))
        XCTAssertNil(ConversationLanguage.dominantLanguageName(of: [], locale: english))
        XCTAssertNil(ConversationLanguage.dominantLanguageName(of: ["12345 67890 · 2025-03-31"], locale: english))
    }

    func testPillLabelNamesTheSourceFallsBackAndShowsProgress() {
        XCTAssertEqual(ConversationTranslationPill.label(sourceLanguageName: "German", progressText: nil), "Translated from German")
        XCTAssertEqual(ConversationTranslationPill.label(sourceLanguageName: nil, progressText: nil), "Translated")
        XCTAssertEqual(ConversationTranslationPill.label(sourceLanguageName: "German", progressText: "1 of 3"), "Translating 1 of 3…")
        _ = ConversationTranslationPill(sourceLanguageName: "German", progressText: nil, showOriginal: {}).body
    }

    func testModelDetectsTheConversationsLanguageAndClearsIt() {
        var seen: [[String]] = []
        let model = ConversationAIPaneModel(
            assistant: ThreadAIAssistantViewModel(assistant: PaneAssistant()),
            translation: ThreadTranslationViewModel(handler: UnconfiguredThreadTranslationHandler()),
            askMail: AskMailViewModel(handler: ScopedAskMailHandler()),
            languageName: { texts in seen.append(texts); return "German" }
        )

        model.setConversation(planContext(selected: "m2"))
        XCTAssertEqual(model.sourceLanguageName, "German")
        XCTAssertEqual(seen.last?.count, 2, "every original body of the conversation")

        model.setConversation(nil)
        XCTAssertNil(model.sourceLanguageName)
    }
}
