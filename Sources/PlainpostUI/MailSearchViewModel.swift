import Combine
import Foundation
import PlainpostCore

public struct MailSearchAccount: Equatable, Sendable, Identifiable {
    public let id: AccountID
    public let displayName: String
    public let email: String

    public init(id: AccountID, displayName: String, email: String) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }
}

public struct MailSearchMailbox: Equatable, Sendable, Identifiable {
    public static let maximumMetadataCount = 500

    public let id: MailboxID
    public let accountID: AccountID
    public let displayName: String

    public init(id: MailboxID, accountID: AccountID, displayName: String) {
        self.id = id
        self.accountID = accountID
        self.displayName = displayName
    }
}

public enum MailSearchViewState: Equatable, Sendable {
    case initial
    case suggesting
    case searching(retainingResults: Bool)
    case results(hasMore: Bool)
    case empty
    case invalid(String)
    case rebuilding
    case unavailable
}

public enum MailSearchSelectionMovement: Equatable, Sendable {
    case up
    case down
}

@MainActor
public final class MailSearchViewModel: ObservableObject {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    private static let maximumAutomaticDuplicatePageDrains = 8

    private enum ResultMergeStrategy {
        case replace
        case append
        case refreshedPrefix
    }

    @Published public var query: String {
        didSet { queryDidChange(query != oldValue) }
    }
    @Published public var mode: MailSearchMode {
        didSet { inputDidChange(mode != oldValue) }
    }
    @Published public var scope: MailSearchSelectionScope {
        didSet { inputDidChange(scope != oldValue) }
    }
    @Published public private(set) var rows: [MailSearchHit]
    @Published public private(set) var suggestions: [MailSearchSuggestionSection]
    @Published public private(set) var state: MailSearchViewState
    @Published public var selectedHitID: String?
    @Published public private(set) var accounts: [MailSearchAccount]
    @Published public private(set) var mailboxes: [MailSearchMailbox]
    @Published public private(set) var accessibilityAnnouncement: String?

    public var isReplacingResults: Bool {
        if case .searching(retainingResults: true) = state { return true }
        return false
    }

    private let service: any MailSearchService
    private let session: MailSearchSession
    private let sleep: Sleep
    private var debounceTask: Task<Void, Never>?
    private var suggestionDebounceTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var suggestionGeneration = 0
    private var nextCursor: MailSearchCursor?
    private var completedRequest: MailSearchRequest?
    private var failedRequest: MailSearchRequest?
    private var failedSuggestionRequest: MailSearchSuggestionRequest?
    private var presentedSuggestionQuery: String?
    private var presentedSuggestionGeneration: Int?
    private var textSelection = MailSearchTextRange(location: 0, length: 0)
    private var staleCursorRestarted = false
    private var isLoadingNextPage = false
    private var isApplyingReset = false

    public init(
        accounts: [MailSearchAccount],
        mailboxes: [MailSearchMailbox] = [],
        service: any MailSearchService,
        session: MailSearchSession = MailSearchSession(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.accounts = accounts
        self.mailboxes = Self.boundedMailboxes(mailboxes)
        self.service = service
        self.session = session
        self.sleep = sleep
        query = ""
        mode = .conversations
        scope = MailSearchSelectionScope()
        rows = []
        suggestions = []
        state = .initial
        selectedHitID = nil
        accessibilityAnnouncement = nil
    }

    public func submit() {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty || hasStructuralScope(scope) else {
            clearForEmptyQuery()
            return
        }
        if !normalizedQuery.isEmpty {
            Task { await session.submit(normalizedQuery) }
        }
        beginNewGeneration()
        startFirstPage(
            MailSearchRequest(query: normalizedQuery, scope: scope, mode: mode),
            generation: generation
        )
    }

    public func prepareInitialSearchSuggestions() {
        guard normalize(query).isEmpty, !hasStructuralScope(scope) else { return }
        beginNewSuggestionGeneration()
        startSuggestions(
            rawQuery: query,
            scope: scope,
            selection: textSelection,
            generation: suggestionGeneration,
            suggestionOnly: false
        )
    }

    public func loadNextPageIfNeeded(after stableID: String) {
        guard !isLoadingNextPage,
              rows.last?.id == stableID,
              let completedRequest,
              let nextCursor,
              case .results(hasMore: true) = state else {
            return
        }
        let request = MailSearchRequest(
            query: completedRequest.query,
            scope: completedRequest.scope,
            mode: completedRequest.mode,
            limit: completedRequest.limit,
            cursor: nextCursor
        )
        performSearch(request, generation: generation, mergeStrategy: .append)
    }

    public func retry() {
        if let failedRequest {
            retrySearch(failedRequest)
            return
        }
        guard let failedSuggestionRequest else { return }
        beginNewSuggestionGeneration()
        state = .suggesting
        let requestedGeneration = suggestionGeneration
        suggestionTask = Task { @MainActor [weak self] in
            await self?.performSuggestions(
                failedSuggestionRequest,
                generation: requestedGeneration,
                suggestionOnly: true
            )
        }
    }

    private func retrySearch(_ failedRequest: MailSearchRequest) {
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        self.failedRequest = nil
        staleCursorRestarted = false
        isLoadingNextPage = false
        if failedRequest.cursor == nil {
            startFirstPage(failedRequest, generation: generation)
        } else {
            performSearch(failedRequest, generation: generation, mergeStrategy: .append)
        }
    }

    public func updateTextSelection(_ selection: MailSearchTextRange) {
        guard selection != textSelection,
              selection.location >= 0,
              selection.length >= 0,
              selection.location <= query.utf16.count,
              selection.length <= query.utf16.count - selection.location else {
            return
        }
        let previousContext = MailSearchQueryParser.suggestionContext(
            in: query,
            selection: textSelection
        )
        let nextContext = MailSearchQueryParser.suggestionContext(
            in: query,
            selection: selection
        )
        textSelection = selection
        guard previousContext != nextContext else { return }
        scheduleSuggestionOnly()
    }

    public func validatedSuggestionForApplication(
        _ item: MailSearchSuggestionItem
    ) -> MailSearchSuggestionItem? {
        guard presentedSuggestionGeneration == suggestionGeneration,
              presentedSuggestionQuery == query,
              suggestions.lazy.flatMap(\.items).contains(item) else {
            return nil
        }
        return item
    }

    public func messageToOpen(for hit: MailSearchHit) -> MessageID {
        switch hit {
        case .conversation(let conversation):
            conversation.bestMatchingMessageID
        case .message(let message):
            message.messageID
        }
    }

    public func hitToOpenOnReturn() -> MailSearchHit? {
        guard let completedRequest,
              completedRequest.query == normalize(query),
              completedRequest.scope == scope,
              completedRequest.mode == mode else {
            return nil
        }
        if let selectedHitID,
           let selected = rows.first(where: { $0.id == selectedHitID }) {
            return selected
        }
        return rows.first
    }

    @discardableResult
    public func moveResultSelection(_ movement: MailSearchSelectionMovement) -> Bool {
        guard let first = rows.first, let last = rows.last else { return false }
        guard let selectedHitID,
              let index = rows.firstIndex(where: { $0.id == selectedHitID }) else {
            self.selectedHitID = movement == .down ? first.id : last.id
            return true
        }
        switch movement {
        case .up:
            self.selectedHitID = rows[max(rows.startIndex, index - 1)].id
        case .down:
            self.selectedHitID = rows[min(rows.index(before: rows.endIndex), index + 1)].id
        }
        return true
    }

    /// Starts a fresh search for `query`. `accountScope` replaces the accounts searched (empty
    /// is every account, one is a search started inside that account's folder); nil keeps the
    /// current choice.
    public func reset(query: String, accounts: [MailSearchAccount], accountScope: [AccountID]? = nil) {
        beginNewGeneration()
        isApplyingReset = true
        self.accounts = accounts
        if let accountScope {
            scope = MailSearchSelectionScope(accountIDs: accountScope, mailboxIDs: [])
        }
        self.scope = reconciledAccountScope(scope, accounts: accounts)
        self.query = query
        textSelection = .init(location: query.utf16.count, length: 0)
        isApplyingReset = false
        accessibilityAnnouncement = nil
        rows = []
        suggestions = []
        selectedHitID = nil
        state = .initial
        guard !normalize(query).isEmpty || hasStructuralScope(scope) else { return }
        scheduleDebouncedSearch()
    }

    public func updateAccounts(_ accounts: [MailSearchAccount]) {
        guard self.accounts != accounts else { return }
        let oldScope = scope
        isApplyingReset = true
        self.accounts = accounts
        scope = reconciledAccountScope(scope, accounts: accounts)
        isApplyingReset = false
        accessibilityAnnouncement = oldScope == scope
            ? nil
            : "Search scope changed because the selected account is no longer available."
        scheduleDebouncedSearch()
    }

    public func updateMailboxes(_ mailboxes: [MailSearchMailbox]) {
        let bounded = Self.boundedMailboxes(mailboxes)
        guard self.mailboxes != bounded else { return }
        let oldScope = scope
        isApplyingReset = true
        self.mailboxes = bounded
        scope = reconciledMailboxScope(scope, mailboxes: bounded)
        isApplyingReset = false
        accessibilityAnnouncement = oldScope == scope
            ? nil
            : "Search scope changed because a selected mailbox is no longer available."
        scheduleDebouncedSearch()
    }

    private func inputDidChange(_ changed: Bool) {
        guard changed, !isApplyingReset else { return }
        scheduleDebouncedSearch()
    }

    private func queryDidChange(_ changed: Bool) {
        guard changed, !isApplyingReset else { return }
        textSelection = .init(location: query.utf16.count, length: 0)
        scheduleDebouncedSearch()
    }

    private func scheduleDebouncedSearch() {
        beginNewGeneration()
        let rawQuery = query
        let normalizedQuery = normalize(query)
        let scopedMatchAll = normalizedQuery.isEmpty && hasStructuralScope(scope)
        guard !normalizedQuery.isEmpty || scopedMatchAll else {
            clearForEmptyQuery()
            return
        }
        let requestedGeneration = generation
        let requestedScope = scope
        let requestedMode = mode
        let requestedSuggestionGeneration = suggestionGeneration
        let requestedSelection = textSelection
        let shouldSearch = scopedMatchAll || isAutomaticSearchEligible(normalizedQuery)
        state = shouldSearch
            ? .searching(retainingResults: !rows.isEmpty)
            : .suggesting
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleep(.milliseconds(250))
                try Task.checkCancellation()
                guard requestedGeneration == generation else { return }
                if shouldSearch {
                    startFirstPage(
                        MailSearchRequest(
                            query: normalizedQuery,
                            scope: requestedScope,
                            mode: requestedMode
                        ),
                        generation: requestedGeneration
                    )
                }
                guard requestedSuggestionGeneration == suggestionGeneration else { return }
                startSuggestions(
                    rawQuery: rawQuery,
                    scope: requestedScope,
                    selection: requestedSelection,
                    generation: requestedSuggestionGeneration,
                    suggestionOnly: !shouldSearch
                )
            } catch {
                guard requestedGeneration == generation, !Task.isCancelled else { return }
                if !shouldSearch { apply(error) }
            }
        }
    }

    private func beginNewGeneration() {
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        beginNewSuggestionGeneration()
        nextCursor = nil
        completedRequest = nil
        failedRequest = nil
        staleCursorRestarted = false
        isLoadingNextPage = false
        selectedHitID = nil
    }

    private func beginNewSuggestionGeneration() {
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionGeneration &+= 1
        suggestions = []
        failedSuggestionRequest = nil
        presentedSuggestionQuery = nil
        presentedSuggestionGeneration = nil
    }

    private func scheduleSuggestionOnly() {
        beginNewSuggestionGeneration()
        let rawQuery = query
        guard !normalize(rawQuery).isEmpty else { return }
        let requestedGeneration = suggestionGeneration
        let requestedScope = scope
        let requestedSelection = textSelection
        suggestionDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleep(.milliseconds(250))
                try Task.checkCancellation()
                guard requestedGeneration == suggestionGeneration else { return }
                startSuggestions(
                    rawQuery: rawQuery,
                    scope: requestedScope,
                    selection: requestedSelection,
                    generation: requestedGeneration,
                    suggestionOnly: !isAutomaticSearchEligible(normalize(rawQuery))
                )
            } catch {
                return
            }
        }
    }

    private func startSuggestions(
        rawQuery: String,
        scope: MailSearchSelectionScope,
        selection: MailSearchTextRange,
        generation requestedGeneration: Int,
        suggestionOnly: Bool
    ) {
        guard requestedGeneration == suggestionGeneration else { return }
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recentQueries = await session.recentQueries()
            let context = MailSearchQueryParser.suggestionContext(
                in: rawQuery,
                selection: selection
            )
            let request = MailSearchSuggestionRequest(
                query: rawQuery,
                scope: scope,
                recentQueries: recentQueries,
                activeRange: context?.replacementRange
            )
            await performSuggestions(
                request,
                generation: requestedGeneration,
                suggestionOnly: suggestionOnly
            )
        }
    }

    private func performSuggestions(
        _ request: MailSearchSuggestionRequest,
        generation requestedGeneration: Int,
        suggestionOnly: Bool
    ) async {
        do {
            let sections = try await service.suggestions(request)
            try Task.checkCancellation()
            guard requestedGeneration == suggestionGeneration,
                  request.query == query,
                  request.scope == scope else { return }
            suggestions = sections
            failedSuggestionRequest = nil
            presentedSuggestionQuery = request.query
            presentedSuggestionGeneration = requestedGeneration
            if suggestionOnly { state = .suggesting }
        } catch {
            guard requestedGeneration == suggestionGeneration, !Task.isCancelled else { return }
            failedSuggestionRequest = request
            if suggestionOnly { apply(error) }
        }
    }

    private func startFirstPage(
        _ request: MailSearchRequest,
        generation requestedGeneration: Int
    ) {
        guard requestedGeneration == generation else { return }
        state = .searching(retainingResults: !rows.isEmpty)
        performSearch(request, generation: requestedGeneration, mergeStrategy: .replace)
    }

    private func performSearch(
        _ request: MailSearchRequest,
        generation requestedGeneration: Int,
        mergeStrategy: ResultMergeStrategy,
        automaticDuplicatePageDrainCount: Int = 0,
        drainedCursorValues: [String] = []
    ) {
        guard requestedGeneration == generation else { return }
        if case .append = mergeStrategy { isLoadingNextPage = true }
        failedRequest = nil
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await service.search(request)
                try Task.checkCancellation()
                guard requestedGeneration == generation else { return }
                isLoadingNextPage = false
                let previousRowCount = rows.count
                rows = merged(response.hits, strategy: mergeStrategy)
                nextCursor = response.nextCursor
                completedRequest = MailSearchRequest(
                    query: request.query,
                    scope: request.scope,
                    mode: request.mode,
                    limit: request.limit
                )
                failedRequest = nil
                if let requestedCursor = request.cursor,
                   response.nextCursor == requestedCursor {
                    failedRequest = request
                    apply(MailSearchError.invalidCursor)
                    return
                }
                if case .append = mergeStrategy,
                   rows.count == previousRowCount,
                   let continuationCursor = response.nextCursor {
                    let continuationRequest = MailSearchRequest(
                        query: request.query,
                        scope: request.scope,
                        mode: request.mode,
                        limit: request.limit,
                        cursor: continuationCursor
                    )
                    guard automaticDuplicatePageDrainCount
                            < Self.maximumAutomaticDuplicatePageDrains,
                          !drainedCursorValues.contains(continuationCursor.rawValue) else {
                        failedRequest = continuationRequest
                        apply(MailSearchError.invalidCursor)
                        return
                    }
                    state = .searching(retainingResults: !rows.isEmpty)
                    performSearch(
                        continuationRequest,
                        generation: requestedGeneration,
                        mergeStrategy: .append,
                        automaticDuplicatePageDrainCount: automaticDuplicatePageDrainCount + 1,
                        drainedCursorValues: drainedCursorValues
                            + (request.cursor.map { [$0.rawValue] } ?? [])
                    )
                    return
                }
                state = rows.isEmpty
                    ? .empty
                    : .results(hasMore: response.nextCursor != nil)
            } catch {
                guard requestedGeneration == generation, !Task.isCancelled else { return }
                isLoadingNextPage = false
                if request.cursor != nil,
                   (error as? MailSearchError) == .staleCursor,
                   !staleCursorRestarted {
                    staleCursorRestarted = true
                    let restart = MailSearchRequest(
                        query: request.query,
                        scope: request.scope,
                        mode: request.mode,
                        limit: request.limit
                    )
                    state = .searching(retainingResults: !rows.isEmpty)
                    performSearch(
                        restart,
                        generation: requestedGeneration,
                        mergeStrategy: .refreshedPrefix
                    )
                    return
                }
                failedRequest = request
                apply(error)
            }
        }
    }

    private func apply(_ error: any Error) {
        switch error as? MailSearchError {
        case .invalidQuery(let reason, _):
            state = .invalid(Self.safeInvalidQueryMessage(for: reason))
        case .unsupportedField:
            state = .invalid("That search field is not supported.")
        case .unsupportedValue:
            state = .invalid("That search value is not supported.")
        case .requestTooLarge:
            state = .invalid("This search is too long. Remove some terms.")
        case .rebuilding:
            state = .rebuilding
        case .cancelled:
            break
        case .invalidCursor, .staleCursor, .unavailable, .none:
            state = .unavailable
        }
    }

    private static func safeInvalidQueryMessage(for reason: String) -> String {
        switch reason {
        case "Account search scope does not match the selected account.":
            return "Search scope does not match this account. Clear Scope and try again."
        case "Query is empty.",
             "Quoted phrase has a dangling escape.",
             "Quoted phrase contains an unsupported escape.",
             "Quoted phrase is not closed.",
             "Unexpected token.",
             "Nesting is too deep; maximum is 8.",
             "Grouped expression is empty.",
             "Closing parenthesis is missing.",
             "Search value is empty.",
             "Boolean operator is missing an operand.",
             "Expected a search expression.",
             "Structured field value is empty.",
             "Text field contains a structured filter.",
             "Too many terms; maximum is 64.",
             "Too many clauses; maximum is 32.":
            return reason
        default:
            // A service may return arbitrary text. Never surface query or mail content.
            return "Check the search query and try again."
        }
    }

    private func clearForEmptyQuery() {
        rows = []
        suggestions = []
        selectedHitID = nil
        state = .initial
        prepareInitialSearchSuggestions()
    }

    private func deduplicated(_ hits: [MailSearchHit]) -> [MailSearchHit] {
        var seen = Set<String>()
        return hits.filter { seen.insert($0.id).inserted }
    }

    private func merged(
        _ hits: [MailSearchHit],
        strategy: ResultMergeStrategy
    ) -> [MailSearchHit] {
        switch strategy {
        case .replace:
            deduplicated(hits)
        case .append:
            deduplicated(rows + hits)
        case .refreshedPrefix:
            deduplicated(hits + rows)
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAutomaticSearchEligible(_ normalizedQuery: String) -> Bool {
        normalizedQuery.count > 1 || normalizedQuery.contains(":")
    }

    private func hasStructuralScope(_ scope: MailSearchSelectionScope) -> Bool {
        !scope.accountIDs.isEmpty || !scope.mailboxIDs.isEmpty
    }

    private func reconciledAccountScope(
        _ candidate: MailSearchSelectionScope,
        accounts: [MailSearchAccount]
    ) -> MailSearchSelectionScope {
        let validAccountIDs = Set(accounts.map(\.id))
        return MailSearchSelectionScope(
            accountIDs: candidate.accountIDs.filter(validAccountIDs.contains),
            mailboxIDs: candidate.mailboxIDs
        )
    }

    private func reconciledMailboxScope(
        _ candidate: MailSearchSelectionScope,
        mailboxes: [MailSearchMailbox]
    ) -> MailSearchSelectionScope {
        let validMailboxIDs = Set(mailboxes.map(\.id))
        return MailSearchSelectionScope(
            accountIDs: candidate.accountIDs,
            mailboxIDs: candidate.mailboxIDs.filter(validMailboxIDs.contains)
        )
    }

    private static func boundedMailboxes(
        _ mailboxes: [MailSearchMailbox]
    ) -> [MailSearchMailbox] {
        var seen = Set<MailboxID>()
        var result: [MailSearchMailbox] = []
        result.reserveCapacity(min(mailboxes.count, MailSearchMailbox.maximumMetadataCount))
        for mailbox in mailboxes where seen.insert(mailbox.id).inserted {
            result.append(mailbox)
            if result.count == MailSearchMailbox.maximumMetadataCount { break }
        }
        return result
    }

    private convenience init(
        previewState: MailSearchViewState,
        query: String,
        rows: [MailSearchHit] = [],
        suggestions: [MailSearchSuggestionSection] = [],
        mode: MailSearchMode = .conversations
    ) {
        self.init(accounts: Self.previewAccounts, service: PreviewMailSearchService())
        isApplyingReset = true
        self.query = query
        self.mode = mode
        isApplyingReset = false
        textSelection = .init(location: query.utf16.count, length: 0)
        self.rows = deduplicated(rows)
        self.suggestions = suggestions
        if !suggestions.isEmpty {
            presentedSuggestionQuery = query
            presentedSuggestionGeneration = suggestionGeneration
        }
        state = previewState
    }

    public static func designTips() -> MailSearchViewModel {
        MailSearchViewModel(previewState: .initial, query: "")
    }

    public static func designResults() -> MailSearchViewModel {
        MailSearchViewModel(
            previewState: .results(hasMore: false),
            query: "project",
            rows: [previewConversation(id: "preview-project")]
        )
    }

    public static func designSuggestions() -> MailSearchViewModel {
        let range = MailSearchTextRange(location: 0, length: 2)
        let make: (String, String, String, String) -> MailSearchSuggestionItem = {
            MailSearchSuggestionItem(
                id: $0,
                title: $1,
                detail: $2,
                insertion: $3,
                replacementRange: range
            )
        }
        return MailSearchViewModel(
            previewState: .suggesting,
            query: "al",
            suggestions: [
                .init(kind: .recent, items: [
                    make("recent", "from:alex has:attachment", "Recent search", "from:alex has:attachment"),
                ]),
                .init(kind: .people, items: [
                    make("person", "Alex Rivera", "alex@example.com", "participants:alex@example.com"),
                ]),
                .init(kind: .fields, items: [
                    make("field", "after", "Strict lower date boundary.", "after:"),
                ]),
                .init(kind: .filters, items: [
                    make("filter", "has:attachment", "Require the named content type.", "has:attachment"),
                ]),
            ]
        )
    }

    public static func designMessageResults() -> MailSearchViewModel {
        MailSearchViewModel(
            previewState: .results(hasMore: false),
            query: "project",
            rows: [previewMessage(id: "preview-project-message")],
            mode: .messages
        )
    }

    public static func designRetainedLoading() -> MailSearchViewModel {
        MailSearchViewModel(
            previewState: .searching(retainingResults: true),
            query: "budget",
            rows: [previewConversation(id: "preview-retained")]
        )
    }

    public static func designEmpty() -> MailSearchViewModel {
        MailSearchViewModel(previewState: .empty, query: "missing")
    }

    public static func designInvalid() -> MailSearchViewModel {
        MailSearchViewModel(
            previewState: .invalid("Check the search query and try again."),
            query: "before: yesterday"
        )
    }

    public static func designRebuilding() -> MailSearchViewModel {
        MailSearchViewModel(previewState: .rebuilding, query: "project")
    }

    public static func designUnavailable() -> MailSearchViewModel {
        MailSearchViewModel(previewState: .unavailable, query: "project")
    }

    public static var designPreviews: [MailSearchViewModel] {
        [
            designTips(),
            designSuggestions(),
            designResults(),
            designMessageResults(),
            designRetainedLoading(),
            designEmpty(),
            designInvalid(),
            designRebuilding(),
            designUnavailable(),
        ]
    }

    private static let previewAccounts = [
        MailSearchAccount(
            id: AccountID("preview_personal"),
            displayName: "Personal",
            email: "me@example.com"
        )
    ]

    private static func previewConversation(id: String) -> MailSearchHit {
        let snippetText = "<script>alert('mail')</script> The project update is ready."
        let highlight = (snippetText as NSString).range(of: "project")
        return .conversation(.init(
            stableID: id,
            threadID: ThreadID(id),
            accountID: previewAccounts[0].id,
            bestMatchingMessageID: MessageID("preview-message"),
            subject: "Project update",
            participants: ["Alex"],
            latestActivity: Date(timeIntervalSince1970: 1_720_000_000),
            snippet: try! MailSearchSnippet(
                text: snippetText,
                highlights: [.init(location: highlight.location, length: highlight.length)]
            ),
            matchingMessageCount: 1,
            totalMessageCount: 2,
            unreadMessageCount: 1,
            hasAttachments: true,
            hasDocuments: true
        ))
    }

    private static func previewMessage(id: String) -> MailSearchHit {
        .message(.init(
            stableID: id,
            messageID: MessageID(id),
            threadID: ThreadID("preview-thread"),
            accountID: previewAccounts[0].id,
            sender: EmailAddress("alex@example.com"),
            senderDisplayName: "Alex Rivera",
            recipients: [EmailAddress("me@example.com"), EmailAddress("max@example.com")],
            subject: "Project update",
            sentAt: Date(timeIntervalSince1970: 1_720_000_000),
            snippet: try! MailSearchSnippet(
                text: "The project timeline is attached.",
                highlights: [.init(location: 4, length: 7)]
            ),
            isUnread: false,
            isFlagged: true,
            isDelegated: false,
            mailboxIDs: [MailboxID("preview-inbox")],
            hasAttachments: true,
            hasDocuments: true
        ))
    }
}

private struct PreviewMailSearchService: MailSearchService {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        throw MailSearchError.unavailable
    }

    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] { [] }

    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}
    func performMaintenanceIfDue(now: Date) async throws {}
}
