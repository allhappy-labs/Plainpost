import Foundation

/// A mail server's refusal of an archive or delete (an IMAP `NO` or `BAD` to
/// the move or erase), as a short sentence the user can act on. The raw tagged
/// line never reaches the user: its tag and response code are dropped, and a
/// reason that names a UID or other number is left out.
public enum MailActionServerRefusal {
    public enum Action: Sendable {
        case archive, delete

        fileprivate var verb: String {
            switch self {
            case .archive: "archive"
            case .delete: "delete"
            }
        }

        fileprivate var participle: String {
            switch self {
            case .archive: "archived"
            case .delete: "deleted"
            }
        }
    }

    /// The readable error for `error`, or nil when it isn't a server refusal.
    public static func error(for error: Error, action: Action) -> PlainpostError? {
        guard case let IMAPClientError.protocolError(detail) = error else { return nil }
        if detail.hasPrefix("UID MOVE and UID EXPUNGE are unavailable") {
            return .validationFailed("The mail server can't move messages, so this message wasn't \(action.participle).")
        }
        // Only a tagged NO or BAD is the server's refusal; anything else the
        // client raised (a name it won't send, a missing extension) is not.
        guard isRefusal(detail) else {
            return .validationFailed("Plainpost couldn't \(action.verb) this message on the mail server.")
        }
        let refused = "The mail server refused to \(action.verb) this message"
        guard let reason = reason(fromTaggedLine: detail) else { return .validationFailed(refused + ".") }
        return .validationFailed("\(refused): \(reason).")
    }

    private static func isRefusal(_ line: String) -> Bool {
        let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        return words.count >= 2 && ["NO", "BAD"].contains(words[1].uppercased())
    }

    /// Runs `body`, the move or erase, turning a server refusal into its readable error.
    public static func mapping<T>(_ action: Action, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.error(for: error, action: action) ?? error
        }
    }

    /// The human text of `A0007 NO [CODE] text`, or nil when there is none to show.
    private static func reason(fromTaggedLine line: String) -> String? {
        var words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, ["NO", "BAD"].contains(words[1].uppercased()) else { return nil }
        words.removeFirst(2)
        var text = words.joined(separator: " ")
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.count <= 120, !text.contains(where: \.isNumber),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return text
    }
}
