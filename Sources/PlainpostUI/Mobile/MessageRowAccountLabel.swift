import PlainpostCore

/// The small label naming which account a row's message came to, in a list that mixes
/// accounts: the address's local part, or the whole address when two accounts share one.
/// None with a single account, or inside one account's folder.
enum MessageRowAccountLabel {
    static func label(for accountID: AccountID?, accounts: [Account]) -> String? {
        guard accounts.count > 1, let accountID,
              let address = accounts.first(where: { $0.id == accountID })?.email.rawValue else { return nil }
        let localPart = { (address: String) in String(address.split(separator: "@").first ?? Substring(address)) }
        let local = localPart(address)
        let shared = accounts.filter { localPart($0.email.rawValue) == local }.count > 1
        return shared ? address : local
    }
}
