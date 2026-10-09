import Foundation

public struct TranslationLanguageOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let localizedName: String
}

public protocol TranslationLanguagePreferenceStore {
    func selectedLanguageID() -> String?
    func saveSelectedLanguageID(_ languageID: String)
}

public enum TranslationLanguageCatalog {
    public static let defaultLanguageID = "en"

    public static func options(locale: Locale = .current) -> [TranslationLanguageOption] {
        Set(Locale.availableIdentifiers.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        }).compactMap { id in
            guard let name = locale.localizedString(forLanguageCode: id) else { return nil }
            return TranslationLanguageOption(id: id, localizedName: name)
        }
        .sorted {
            let order = $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

public final class UserDefaultsTranslationLanguagePreferenceStore:
    TranslationLanguagePreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "Plainpost.ai.translationLanguageID"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func selectedLanguageID() -> String? {
        defaults.string(forKey: key)
    }

    public func saveSelectedLanguageID(_ languageID: String) {
        defaults.set(languageID, forKey: key)
    }
}

@MainActor
public final class TranslationLanguageSettingsViewModel: ObservableObject {
    public let options: [TranslationLanguageOption]
    @Published public private(set) var selectedLanguageID: String
    @Published public var query = ""

    private let preferenceStore: (any TranslationLanguagePreferenceStore)?

    public init(
        options: [TranslationLanguageOption],
        preferenceStore: (any TranslationLanguagePreferenceStore)? = nil
    ) {
        self.options = options
        self.preferenceStore = preferenceStore

        let storedLanguageID = preferenceStore?.selectedLanguageID()
        let resolvedLanguageID: String
        if let storedLanguageID, options.contains(where: { $0.id == storedLanguageID }) {
            resolvedLanguageID = storedLanguageID
        } else if options.contains(where: { $0.id == TranslationLanguageCatalog.defaultLanguageID }) {
            resolvedLanguageID = TranslationLanguageCatalog.defaultLanguageID
        } else {
            resolvedLanguageID = options.first?.id ?? TranslationLanguageCatalog.defaultLanguageID
        }

        selectedLanguageID = resolvedLanguageID
        if storedLanguageID != resolvedLanguageID {
            preferenceStore?.saveSelectedLanguageID(resolvedLanguageID)
        }
    }

    public var selectedOption: TranslationLanguageOption {
        options.first { $0.id == selectedLanguageID }
            ?? TranslationLanguageOption(id: "en", localizedName: "English")
    }

    public var filteredOptions: [TranslationLanguageOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.id.localizedCaseInsensitiveContains(needle)
                || $0.localizedName.localizedCaseInsensitiveContains(needle)
        }
    }

    public func selectLanguage(_ id: String) {
        guard options.contains(where: { $0.id == id }) else { return }
        selectedLanguageID = id
        preferenceStore?.saveSelectedLanguageID(id)
    }
}
