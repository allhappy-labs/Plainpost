import XCTest
@testable import PlainpostUI

@MainActor
final class TranslationLanguageSettingsTests: XCTestCase {
    func testEnglishIsDefaultAndIsPersisted() throws {
        let suite = "TranslationLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTranslationLanguagePreferenceStore(defaults: defaults)

        let first = TranslationLanguageSettingsViewModel(
            options: [.init(id: "de", localizedName: "German"),
                      .init(id: "en", localizedName: "English")],
            preferenceStore: store
        )
        XCTAssertEqual(first.selectedLanguageID, "en")

        first.selectLanguage("de")
        let second = TranslationLanguageSettingsViewModel(
            options: first.options,
            preferenceStore: store
        )
        XCTAssertEqual(second.selectedLanguageID, "de")
    }

    func testSearchMatchesLocalizedNameAndIdentifier() {
        let viewModel = TranslationLanguageSettingsViewModel(
            options: [.init(id: "de", localizedName: "German"),
                      .init(id: "en", localizedName: "English")],
            preferenceStore: nil
        )
        viewModel.query = "ger"
        XCTAssertEqual(viewModel.filteredOptions.map(\.id), ["de"])
        viewModel.query = "en"
        XCTAssertEqual(viewModel.filteredOptions.map(\.id), ["en"])
    }
}
