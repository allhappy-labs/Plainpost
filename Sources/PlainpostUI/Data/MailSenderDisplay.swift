import Foundation

/// How a sender is shown: display name, else the name part of a
/// `Name <address>` string, else the bare address. Never the raw header.
enum MailSenderDisplay {
    static func name(displayName: String?, address: String) -> String {
        explicitName(displayName: displayName, address: address) ?? Self.address(address)
    }

    /// The sender's own name, from the display name or the `Name <address>` form; nil when
    /// the sender is a bare address.
    static func explicitName(displayName: String?, address: String) -> String? {
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = namePart(of: trimmed), !parsed.isEmpty { return parsed }
            if !trimmed.isEmpty, !trimmed.contains("<") { return trimmed }
        }
        if let parsed = namePart(of: address), !parsed.isEmpty { return parsed }
        return nil
    }

    static func address(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"),
              let close = trimmed[open...].firstIndex(of: ">") else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func namePart(of raw: String) -> String? {
        guard let open = raw.lastIndex(of: "<") else { return nil }
        let name = raw[..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.contains("@") ? nil : name
    }
}
