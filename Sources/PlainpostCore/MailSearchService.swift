import Foundation

public protocol MailSearchService: Sendable {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse
    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection]
    func indexState() async -> MailSearchIndexState
    func rebuildIndex() async throws
    func performMaintenanceIfDue(now: Date) async throws
}

public actor MailSearchSession {
    private let capacity: Int
    private var queries: [String] = []

    public init(capacity: Int = 10) {
        self.capacity = min(10, max(1, capacity))
    }

    public func submit(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        queries.insert(query, at: 0)
        queries = Array(queries.prefix(capacity))
    }

    public func recentQueries() -> [String] {
        queries
    }

    public func clear() {
        queries.removeAll(keepingCapacity: false)
    }
}
