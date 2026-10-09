import Foundation
import PlainpostCore

/// The account New Message sends from by default: the last one the user sent from on this
/// device, else the first account.
struct ComposerFromAccountPreference {
    static let key = "plainpost.compose.last-from-account"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func defaultAccount(among accounts: [Account]) -> Account? {
        if let saved = defaults.string(forKey: Self.key),
           let account = accounts.first(where: { $0.id.rawValue == saved }) {
            return account
        }
        return accounts.first
    }

    func recordSent(from accountID: AccountID) {
        defaults.set(accountID.rawValue, forKey: Self.key)
    }
}
