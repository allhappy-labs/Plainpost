import Foundation

public enum SiteIconPreference {
    public static let fetchEnabledKey = "Plainpost.privacy.fetchSiteIcons"

    public static func fetchEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: fetchEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: fetchEnabledKey)
    }
}

struct SiteIconDomain: Hashable, Sendable {
    let host: String

    init?(sender: String) {
        let address = MailContact.normalizedEmail(sender)
        guard let rawHost = address.split(separator: "@", maxSplits: 1).dropFirst().first else {
            return nil
        }

        let host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAllowed(host: host) else {
            return nil
        }

        self.host = host
    }

    var faviconURL: URL {
        URL(string: "https://\(host)/favicon.ico")!
    }

    private static func isAllowed(host: String) -> Bool {
        guard host.contains("."),
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \ .isEmpty) else {
            return false
        }

        let isIPv4Address = labels.count == 4 && labels.allSatisfy { label in
            guard let value = UInt8(label) else { return false }
            return String(value) == label || (value == 0 && label == "0")
        }
        return !isIPv4Address
    }
}
