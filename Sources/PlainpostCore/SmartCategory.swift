import Foundation

public enum SmartCategory: String, CaseIterable, Codable, Sendable {
    case personal
    case notification
    case newsletter
    case receipt
    case security
    case finance
    case travel
    case support
    case social
    case system
    case invitation
    case invitationResponse = "invitation_response"
    case unknown
}

public struct CategoryInput: Equatable, Sendable {
    public let from: String
    public let subject: String
    public let headers: [String: String]
    public let bodyPreview: String

    public init(from: String, subject: String, headers: [String: String], bodyPreview: String) {
        self.from = from
        self.subject = subject
        self.headers = headers
        self.bodyPreview = bodyPreview
    }
}

public struct CategoryResult: Equatable, Sendable {
    public let category: SmartCategory
    public let confidence: Double
    public let reason: String

    public init(category: SmartCategory, confidence: Double, reason: String) {
        self.category = category
        self.confidence = confidence
        self.reason = reason
    }
}

public struct SmartCategoryClassifier: Sendable {
    public init() {}

    public func classify(_ input: CategoryInput) -> CategoryResult {
        let headers = Dictionary(uniqueKeysWithValues: input.headers.map { key, value in
            (key.lowercased(), value.lowercased())
        })
        let sender = input.from.lowercased()
        let subject = input.subject.lowercased()
        let body = input.bodyPreview.lowercased()

        if headers["list-unsubscribe"] != nil {
            return CategoryResult(category: .newsletter, confidence: 0.9, reason: "List-Unsubscribe header indicates subscription mail.")
        }

        if headers["precedence"]?.contains("bulk") == true {
            return CategoryResult(category: .newsletter, confidence: 0.82, reason: "Bulk precedence indicates subscription or marketing mail.")
        }

        if headers["auto-submitted"] != nil || sender.contains("no-reply") || sender.contains("noreply") {
            return CategoryResult(category: .notification, confidence: 0.86, reason: "Automated sender or header indicates notification mail.")
        }

        if subject.contains("receipt") || subject.contains("invoice") || body.contains("order confirmation") {
            return CategoryResult(category: .receipt, confidence: 0.78, reason: "Receipt or order wording found.")
        }

        if isHumanLike(sender: sender) {
            return CategoryResult(category: .personal, confidence: 0.72, reason: "Sender looks like a person rather than an automated source.")
        }

        return CategoryResult(category: .unknown, confidence: 0.4, reason: "No high-confidence local rule matched.")
    }

    private func isHumanLike(sender: String) -> Bool {
        let localPart = sender.split(separator: "@", maxSplits: 1).first.map(String.init) ?? sender
        if localPart.contains("-") || localPart.contains("_") || localPart.contains(".") {
            return true
        }

        let automatedWords = ["news", "newsletter", "support", "billing", "security", "alerts", "notify", "notification", "system"]
        if automatedWords.contains(where: { localPart.contains($0) }) {
            return false
        }

        return localPart.allSatisfy { $0.isLetter } && (3...32).contains(localPart.count)
    }
}
