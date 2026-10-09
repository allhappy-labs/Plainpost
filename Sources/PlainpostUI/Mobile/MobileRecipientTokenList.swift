import Foundation

/// A recipient field's comma-separated text as committed addresses plus the fragment being
/// typed. `ComposerViewModel` keeps the text; the token UI edits it through this.
struct MobileRecipientTokenList: Equatable {
    private(set) var tokens: [String]
    private(set) var fragment: String
    /// The token a tap selected. Removing a token takes this deliberate step first, as in Apple
    /// Mail: a single tap never removes one.
    private(set) var selected: String?

    /// Text as typed: every part before the last comma is a token; the rest is the fragment.
    init(text: String) {
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        tokens = parts.dropLast().filter { !$0.isEmpty }
        fragment = parts.last ?? ""
    }

    /// Text set from outside (a reply's recipients, a restored draft): every part is a token.
    /// It splits where the composer's recipient parsing does: commas, semicolons, line breaks.
    static func prefilled(_ text: String) -> MobileRecipientTokenList {
        var list = MobileRecipientTokenList(text: "")
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            list.commit(String(part))
        }
        return list
    }

    /// The composer's text: "a@x, b@y, " and then the fragment.
    var text: String { tokens.map { "\($0), " }.joined() + fragment }

    /// The committed addresses, lowercased, for leaving them out of suggestions.
    var excluded: Set<String> { Set(tokens.map { $0.lowercased() }) }

    /// Adds `address` as a token, once ignoring case, and clears the fragment.
    mutating func commit(_ address: String) {
        selected = nil
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !excluded.contains(trimmed.lowercased()) { tokens.append(trimmed) }
        fragment = ""
    }

    /// Typing. A trailing comma or semicolon commits what came before it; a trailing space
    /// does too, but only after something that looks like an address.
    mutating func setFragment(_ typed: String) {
        selected = nil
        guard let last = typed.last else { fragment = ""; return }
        let before = String(typed.dropLast())
        if last == "," || last == ";" || (last == " " && before.contains("@")) {
            commit(before)
        } else {
            fragment = typed
        }
    }

    mutating func remove(_ address: String) {
        tokens.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        if let selected, selected.caseInsensitiveCompare(address) == .orderedSame { self.selected = nil }
    }

    /// A tap on a token: selects it, or clears the selection when it was already selected.
    mutating func toggleSelection(_ token: String) {
        selected = selected == token ? nil : token
    }

    /// Removes the selected token, if there is one.
    mutating func removeSelected() {
        guard let selected else { return }
        remove(selected)
    }
}
