import Foundation
import GRDB
import PlainpostCore

public final class SQLiteMailSearchService: MailSearchService, @unchecked Sendable {
    private let databasePool: DatabasePool
    private let selectedAccountID: AccountID?
    private let parser: MailSearchQueryParser
    private let compiler: SQLiteMailSearchQueryCompiler
    private let cursorCodec: MailSearchCursorCodec
    private let now: @Sendable () -> Date
    private let snippetMarkerNonce: @Sendable () -> String
    private let rebuildWillPublishReady: @Sendable () -> Void
    private let rebuildDidCommitReady: @Sendable () -> Void
    private let maintenanceOptimize: @Sendable (Database) throws -> Void

    public init(store: SQLiteMailStore) {
        databasePool = store.databasePool
        selectedAccountID = nil
        parser = MailSearchQueryParser()
        compiler = SQLiteMailSearchQueryCompiler()
        cursorCodec = MailSearchCursorCodec()
        now = { Date() }
        snippetMarkerNonce = { UUID().uuidString.lowercased() }
        rebuildWillPublishReady = {}
        rebuildDidCommitReady = {}
        maintenanceOptimize = { try $0.execute(sql: "PRAGMA optimize") }
    }

    /// Bind every search and suggestion read to one selected provider account.
    /// Use this for a device mail runtime; `init(store:)` deliberately retains
    /// the Mac/CLI all-account search contract.
    public init(store: SQLiteMailStore, selectedAccountID: AccountID) {
        databasePool = store.databasePool
        self.selectedAccountID = selectedAccountID
        parser = MailSearchQueryParser()
        compiler = SQLiteMailSearchQueryCompiler()
        cursorCodec = MailSearchCursorCodec()
        now = { Date() }
        snippetMarkerNonce = { UUID().uuidString.lowercased() }
        rebuildWillPublishReady = {}
        rebuildDidCommitReady = {}
        maintenanceOptimize = { try $0.execute(sql: "PRAGMA optimize") }
    }

    public convenience init(
        store: SQLiteMailStore,
        databasePath: String
    ) throws {
        try self.init(
            store: store,
            now: { Date() },
            cursorAuthenticationKey: MailSearchCursorAuthenticationKeyStore.loadOrCreate(
                forDatabasePath: databasePath
            )
        )
    }

    package init(
        store: SQLiteMailStore,
        selectedAccountID: AccountID? = nil,
        now: @escaping @Sendable () -> Date,
        cursorAuthenticationKey: Data,
        snippetMarkerNonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        rebuildWillPublishReady: @escaping @Sendable () -> Void = {},
        rebuildDidCommitReady: @escaping @Sendable () -> Void = {},
        maintenanceOptimize: @escaping @Sendable (Database) throws -> Void = {
            try $0.execute(sql: "PRAGMA optimize")
        }
    ) {
        databasePool = store.databasePool
        self.selectedAccountID = selectedAccountID
        parser = MailSearchQueryParser()
        compiler = SQLiteMailSearchQueryCompiler()
        cursorCodec = MailSearchCursorCodec(authenticationKey: cursorAuthenticationKey)
        self.now = now
        self.snippetMarkerNonce = snippetMarkerNonce
        self.rebuildWillPublishReady = rebuildWillPublishReady
        self.rebuildDidCommitReady = rebuildDidCommitReady
        self.maintenanceOptimize = maintenanceOptimize
    }

    public func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        do {
            try Task.checkCancellation()
            let request = try boundRequest(request)
            try request.validate()
            let currentTime = now()
            let authenticatedCursor = try request.cursor.map {
                try cursorCodec.authenticate($0, now: currentTime)
            }
            let resolutionAnchor = authenticatedCursor?.resolutionAnchor ?? currentTime
            let parsed = try parser.parse(request, now: resolutionAnchor)
            let fingerprint = cursorCodec.fingerprint(
                for: compiler.fingerprintInput(parsed: parsed, request: request)
            )
            let snippetMarkers = SQLiteMailSearchSnippetMarkers(nonce: snippetMarkerNonce())
            let output = try await databasePool.read { [compiler, cursorCodec] database in
                let revision = try Self.searchRevision(
                    database: database,
                    scope: request.scope,
                    cursorCodec: cursorCodec
                )
                let boundary: SQLiteMailSearchCursorBoundary?
                if let authenticatedCursor {
                    boundary = try cursorCodec.validate(
                        authenticatedCursor,
                        fingerprint: fingerprint,
                        mode: request.mode,
                        scope: request.scope,
                        limit: request.limit,
                        revision: revision
                    )
                } else {
                    boundary = nil
                }
                let compiled = try compiler.compile(
                    parsed,
                    request: request,
                    cursor: boundary,
                    snippetMarkers: snippetMarkers
                )
                let rows = try SearchRow.fetchAll(
                    database,
                    sql: compiled.sql,
                    arguments: compiled.arguments
                )
                let aggregateRows: [ConversationAggregateRow]
                if request.mode == .conversations {
                    aggregateRows = try Self.fetchConversationAggregates(
                        database: database,
                        winners: Array(rows.prefix(request.limit))
                    )
                } else {
                    aggregateRows = []
                }
                return SearchReadOutput(
                    rows: rows,
                    conversationAggregates: Dictionary(
                        uniqueKeysWithValues: aggregateRows.map { ($0.key, $0) }
                    ),
                    revision: revision,
                    snippetMarkers: compiled.ftsQuery == nil ? nil : snippetMarkers
                )
            }
            try Task.checkCancellation()

            let hasMore = output.rows.count > request.limit
            let retainedRows = Array(output.rows.prefix(request.limit))
            let hits = try retainedRows.map { row -> MailSearchHit in
                switch request.mode {
                case .messages:
                    return .message(try Self.makeHit(row, snippetMarkers: output.snippetMarkers))
                case .conversations:
                    guard let aggregate = output.conversationAggregates[row.conversationKey] else {
                        throw MailSearchError.unavailable
                    }
                    return .conversation(try Self.makeConversationHit(
                        row,
                        aggregate: aggregate,
                        snippetMarkers: output.snippetMarkers
                    ))
                }
            }
            let nextCursor: MailSearchCursor?
            if hasMore, let last = retainedRows.last {
                nextCursor = try cursorCodec.encode(
                    boundary: .init(
                        exactTier: last.exactTier,
                        lexicalScore: last.lexicalScore,
                        sortDate: last.sortDate,
                        stableID: request.mode == .conversations
                            ? last.stableID
                            : last.messageID,
                        activityDate: request.mode == .conversations
                            ? last.conversationActivity
                            : last.sortDate,
                        conversationID: request.mode == .conversations
                            ? last.conversationID
                            : last.messageID
                    ),
                    resolutionAnchor: resolutionAnchor,
                    fingerprint: fingerprint,
                    mode: request.mode,
                    scope: request.scope,
                    limit: request.limit,
                    revision: output.revision
                )
            } else {
                nextCursor = nil
            }

            return MailSearchResponse(
                parsedQuery: parsed,
                mode: request.mode,
                scope: request.scope,
                hits: hits,
                nextCursor: nextCursor,
                indexRevision: output.revision
            )
        } catch let error as MailSearchError {
            throw error
        } catch is CancellationError {
            throw MailSearchError.cancelled
        } catch let error as DatabaseError where Task.isCancelled && error.isInterruptionError {
            throw MailSearchError.cancelled
        } catch {
            if Task.isCancelled {
                throw MailSearchError.cancelled
            }
            throw MailSearchError.unavailable
        }
    }

    public func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] {
        do {
            try Task.checkCancellation()
            let request = try boundRequest(request)
            try MailSearchScopeContract.validate(request.scope)
            let context = SuggestionContext(request: request)
            let databaseSuggestions = try await databasePool.read { database in
                try Task.checkCancellation()
                let people = context.acceptsPeople
                    ? try Self.peopleSuggestions(database: database, request: request, context: context)
                    : []
                let mailboxes = context.activeField == "mailbox"
                    ? try Self.mailboxSuggestions(database: database, request: request, context: context)
                    : []
                return (people, mailboxes)
            }
            try Task.checkCancellation()

            let proposed: [(MailSearchSuggestionKind, [MailSearchSuggestionItem])] = [
                (.recent, Self.recentSuggestions(request: request)),
                (.people, databaseSuggestions.0),
                (.fields, Self.fieldSuggestions(context: context)),
                (.filters, Self.filterSuggestions(context: context) + databaseSuggestions.1),
            ]
            var remaining = 30
            var sections: [MailSearchSuggestionSection] = []
            for (kind, items) in proposed where remaining > 0 {
                let retained = Array(items.prefix(remaining))
                guard !retained.isEmpty else { continue }
                sections.append(.init(kind: kind, items: retained))
                remaining -= retained.count
            }
            return sections
        } catch let error as MailSearchError {
            throw error
        } catch is CancellationError {
            throw MailSearchError.cancelled
        } catch let error as DatabaseError where Task.isCancelled && error.isInterruptionError {
            throw MailSearchError.cancelled
        } catch {
            if Task.isCancelled { throw MailSearchError.cancelled }
            throw MailSearchError.unavailable
        }
    }

    public func indexState() async -> MailSearchIndexState {
        do {
            let selectedAccountID = selectedAccountID
            let states = try await databasePool.read { database in
                if let selectedAccountID {
                    return try String.fetchAll(
                        database,
                        sql: "SELECT state FROM mail_search_state WHERE account_id = ?",
                        arguments: [selectedAccountID.rawValue]
                    )
                }
                return try String.fetchAll(database, sql: "SELECT state FROM mail_search_state ORDER BY account_id")
            }
            if selectedAccountID != nil && states.isEmpty { return .unavailable }
            if states.contains(MailSearchIndexState.unavailable.rawValue) { return .unavailable }
            if states.contains(MailSearchIndexState.rebuilding.rawValue) { return .rebuilding }
            if states.contains(MailSearchIndexState.preparing.rawValue) { return .preparing }
            if states.allSatisfy({ $0 == MailSearchIndexState.ready.rawValue }) { return .ready }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    public func rebuildIndex() async throws {
        do {
            try Task.checkCancellation()
            let startedAt = now()
            try await databasePool.write { database in
                try SQLiteMailSearchSchema.markRebuilding(database, now: startedAt)
            }
            try Task.checkCancellation()
            try await databasePool.write { [rebuildWillPublishReady] database in
                try SQLiteMailSearchSchema.rebuildMarked(
                    database,
                    beforeReadyPublication: rebuildWillPublishReady
                )
            }
            rebuildDidCommitReady()
        } catch let error as MailSearchError where error == .rebuilding {
            throw error
        } catch {
            await publishUnavailableAfterRebuildFailure()
            if error is CancellationError || Task.isCancelled {
                throw MailSearchError.cancelled
            }
            if let databaseError = error as? DatabaseError,
               Task.isCancelled && databaseError.isInterruptionError {
                throw MailSearchError.cancelled
            }
            throw MailSearchError.unavailable
        }
    }

    public func performMaintenanceIfDue(now: Date) async throws {
        do {
            try Task.checkCancellation()
            try await databasePool.write { [maintenanceOptimize] database in
                try SQLiteMailSearchSchema.performMaintenanceIfDue(
                    database,
                    now: now,
                    optimize: maintenanceOptimize
                )
            }
        } catch let error as MailSearchError {
            throw error
        } catch is CancellationError {
            throw MailSearchError.cancelled
        } catch let error as DatabaseError where Task.isCancelled && error.isInterruptionError {
            throw MailSearchError.cancelled
        } catch {
            if Task.isCancelled {
                throw MailSearchError.cancelled
            }
            throw MailSearchError.unavailable
        }
    }

    private func publishUnavailableAfterRebuildFailure() async {
        let databasePool = databasePool
        let timestamp = now()
        _ = try? await Task.detached {
            try await databasePool.write { database in
                try SQLiteMailSearchSchema.markUnavailable(database, now: timestamp)
            }
        }.value
    }

    private func boundScope(_ scope: MailSearchSelectionScope) throws -> MailSearchSelectionScope {
        guard let selectedAccountID else { return scope }
        guard scope.accountIDs.isEmpty || scope.accountIDs == [selectedAccountID] else {
            throw MailSearchError.invalidQuery(
                reason: "Account search scope does not match the selected account.", range: nil
            )
        }
        return MailSearchSelectionScope(
            accountIDs: [selectedAccountID], mailboxIDs: scope.mailboxIDs
        )
    }

    private func boundRequest(_ request: MailSearchRequest) throws -> MailSearchRequest {
        MailSearchRequest(
            query: request.query, scope: try boundScope(request.scope),
            mode: request.mode, limit: request.limit, cursor: request.cursor
        )
    }

    private func boundRequest(_ request: MailSearchSuggestionRequest) throws -> MailSearchSuggestionRequest {
        MailSearchSuggestionRequest(
            query: request.query, scope: try boundScope(request.scope),
            // The caller's search history has no account provenance yet.
            // A selected-account service must not show another account's terms.
            recentQueries: selectedAccountID == nil ? request.recentQueries : [],
            activeRange: request.activeRange
        )
    }

    private static func fetchConversationAggregates(
        database: Database,
        winners: [SearchRow]
    ) throws -> [ConversationAggregateRow] {
        guard !winners.isEmpty else { return [] }
        let threaded = Dictionary(grouping: winners.filter { $0.threadID?.isEmpty == false }) {
            $0.accountID
        }
        let threadless = Dictionary(grouping: winners.filter { $0.threadID?.isEmpty != false }) {
            $0.accountID
        }
        var predicates: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        for accountID in threaded.keys.sorted() {
            let threadIDs = Array(Set(threaded[accountID, default: []].compactMap(\.threadID))).sorted()
            guard !threadIDs.isEmpty else { continue }
            predicates.append(
                "(d.account_id = ? AND d.thread_id IN (\(Array(repeating: "?", count: threadIDs.count).joined(separator: ", "))))"
            )
            arguments.append(accountID)
            arguments.append(contentsOf: threadIDs)
        }
        for accountID in threadless.keys.sorted() {
            let messageIDs = Array(Set(threadless[accountID, default: []].map(\.messageID))).sorted()
            guard !messageIDs.isEmpty else { continue }
            predicates.append(
                "(d.account_id = ? AND NULLIF(d.thread_id, '') IS NULL AND d.message_id IN (\(Array(repeating: "?", count: messageIDs.count).joined(separator: ", "))))"
            )
            arguments.append(accountID)
            arguments.append(contentsOf: messageIDs)
        }
        guard !predicates.isEmpty else { return [] }
        let identity = SQLiteMailSearchQueryCompiler.conversationIdentitySQL(alias: "d")
        return try ConversationAggregateRow.fetchAll(
            database,
            sql: """
                SELECT
                    d.account_id,
                    \(identity) AS conversation_id,
                    MAX(d.sort_date) AS latest_activity,
                    COUNT(*) AS total_message_count,
                    SUM(CASE WHEN d.is_seen = 0 THEN 1 ELSE 0 END) AS unread_message_count,
                    MAX(d.has_attachments) AS has_attachments,
                    MAX(d.has_documents) AS has_documents,
                    json_group_array(DISTINCT NULLIF(d.sender_display_name, '')) AS sender_names,
                    json_group_array(DISTINCT NULLIF(d.sender_email, '')) AS sender_emails,
                    json_group_array(DISTINCT NULLIF(d.to_value, '')) AS to_values,
                    json_group_array(DISTINCT NULLIF(d.cc_value, '')) AS cc_values,
                    json_group_array(DISTINCT NULLIF(d.bcc_value, '')) AS bcc_values
                FROM mail_search_documents d
                WHERE d.is_deleted = 0
                  AND (\(predicates.joined(separator: " OR ")))
                GROUP BY d.account_id, conversation_id
                """,
            arguments: StatementArguments(arguments)
        )
    }

    private static func makeConversationHit(
        _ row: SearchRow,
        aggregate: ConversationAggregateRow,
        snippetMarkers: SQLiteMailSearchSnippetMarkers?
    ) throws -> MailConversationSearchHit {
        let accountID = AccountID(row.accountID)
        let threadID = row.threadID.flatMap { $0.isEmpty ? nil : $0 }
            ?? row.conversationID
        return MailConversationSearchHit(
            stableID: row.conversationID,
            threadID: ThreadID(threadID),
            accountID: accountID,
            bestMatchingMessageID: MessageID(row.messageID),
            subject: row.subject,
            participants: aggregate.participants,
            latestActivity: aggregate.latestActivity > 0
                ? Date(timeIntervalSince1970: aggregate.latestActivity)
                : nil,
            snippet: safeSnippet(
                from: row.markedSnippet,
                markers: snippetMarkers,
                allowHighlights: !row.sourceContainsSnippetMarkers
            ),
            matchingMessageCount: row.matchingMessageCount,
            totalMessageCount: aggregate.totalMessageCount,
            unreadMessageCount: aggregate.unreadMessageCount,
            hasAttachments: aggregate.hasAttachments,
            hasDocuments: aggregate.hasDocuments,
            bestMatchSender: row.senderEmail.isEmpty ? nil : EmailAddress(row.senderEmail),
            bestMatchSenderDisplayName: row.senderDisplayName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func recentSuggestions(
        request: MailSearchSuggestionRequest
    ) -> [MailSearchSuggestionItem] {
        let replacement = MailSearchTextRange(location: 0, length: request.query.utf16.count)
        return request.recentQueries.map { query in
            .init(
                id: "recent:\(query.utf8.count):\(query.lowercased())",
                title: query,
                detail: "Recent search",
                insertion: query,
                replacementRange: replacement
            )
        }
    }

    private static func peopleSuggestions(
        database: Database,
        request: MailSearchSuggestionRequest,
        context: SuggestionContext
    ) throws -> [MailSearchSuggestionItem] {
        var predicates = ["d.is_deleted = 0", "d.is_trash = 0", "d.sender_email <> ''"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        let fragment = context.fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fragment.isEmpty {
            let pattern = escapedLikePrefix(fragment.lowercased())
            predicates.append(
                "(lower(COALESCE(d.sender_display_name, '')) LIKE ? ESCAPE '\\' OR lower(d.sender_email) LIKE ? ESCAPE '\\')"
            )
            arguments.append(pattern)
            arguments.append(pattern)
        }
        appendScopePredicates(
            scope: request.scope,
            alias: "d",
            predicates: &predicates,
            arguments: &arguments
        )
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT
                    lower(d.sender_email) AS folded_email,
                    d.sender_email,
                    MAX(NULLIF(d.sender_display_name, '')) AS sender_display_name,
                    MAX(d.sort_date) AS latest_activity
                FROM mail_search_documents d
                WHERE \(predicates.map { "(\($0))" }.joined(separator: " AND "))
                GROUP BY lower(d.sender_email)
                ORDER BY latest_activity DESC, folded_email ASC
                LIMIT 10
                """,
            arguments: StatementArguments(arguments)
        )
        return rows.map { row in
            let email: String = row["sender_email"]
            let displayName: String? = row["sender_display_name"]
            let title = displayName ?? email
            let insertion = context.activeField == nil
                ? "participants:\(quotedIfNeeded(email))"
                : quotedIfNeeded(email)
            return MailSearchSuggestionItem(
                id: "person:\(email.lowercased())",
                title: title,
                detail: displayName == nil ? "Sender" : email,
                insertion: insertion,
                replacementRange: context.replacementRange
            )
        }
    }

    private static func fieldSuggestions(
        context: SuggestionContext
    ) -> [MailSearchSuggestionItem] {
        guard context.activeField == nil else { return [] }
        let folded = context.fragment.lowercased()
        return MailSearchFieldRegistry.all.compactMap { definition in
            guard folded.isEmpty
                    || definition.name.hasPrefix(folded)
                    || definition.aliases.contains(where: { $0.hasPrefix(folded) })
            else { return nil }
            return MailSearchSuggestionItem(
                id: "field:\(definition.name)",
                title: definition.name,
                detail: definition.description,
                insertion: "\(definition.name):",
                replacementRange: context.replacementRange
            )
        }
    }

    private static func filterSuggestions(
        context: SuggestionContext
    ) -> [MailSearchSuggestionItem] {
        let values: [String: [String]] = [
            "has": ["attachment", "document"],
            "with": ["attachments", "documents"],
            "is": ["unread", "read", "flagged", "delegated"],
            "in": ["inbox", "sent", "trash"],
        ]
        let fields: [MailSearchFieldDefinition]
        if let activeField = context.activeField,
           let definition = MailSearchFieldRegistry.definition(for: activeField),
           values[definition.name] != nil {
            fields = [definition]
        } else if context.activeField == nil {
            fields = MailSearchFieldRegistry.all.filter { values[$0.name] != nil }
        } else {
            return []
        }
        let folded = context.fragment.lowercased()
        return fields.flatMap { definition in
            values[definition.name, default: []].compactMap { value in
                let complete = "\(definition.name):\(value)"
                let matches = context.activeField == nil
                    ? folded.isEmpty || complete.localizedCaseInsensitiveContains(folded)
                    : folded.isEmpty || value.hasPrefix(folded)
                guard matches else { return nil }
                return MailSearchSuggestionItem(
                    id: "filter:\(complete)",
                    title: complete,
                    detail: definition.description,
                    insertion: context.activeField == nil ? complete : value,
                    replacementRange: context.replacementRange
                )
            }
        }
    }

    private static func mailboxSuggestions(
        database: Database,
        request: MailSearchSuggestionRequest,
        context: SuggestionContext
    ) throws -> [MailSearchSuggestionItem] {
        var predicates: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        let fragment = context.fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fragment.isEmpty {
            predicates.append("lower(name) LIKE ? ESCAPE '\\'")
            arguments.append(escapedLikePrefix(fragment.lowercased()))
        }
        if !request.scope.accountIDs.isEmpty {
            predicates.append(
                "account_id IN (\(Array(repeating: "?", count: request.scope.accountIDs.count).joined(separator: ", ")))"
            )
            arguments.append(contentsOf: request.scope.accountIDs.map(\.rawValue))
        }
        if !request.scope.mailboxIDs.isEmpty {
            predicates.append(
                "id IN (\(Array(repeating: "?", count: request.scope.mailboxIDs.count).joined(separator: ", ")))"
            )
            arguments.append(contentsOf: request.scope.mailboxIDs.map(\.rawValue))
        }
        let whereClause = predicates.isEmpty
            ? ""
            : "WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, name FROM mailboxes
                \(whereClause)
                ORDER BY lower(name), id
                LIMIT 8
                """,
            arguments: StatementArguments(arguments)
        )
        return rows.map { row in
            let mailboxID: String = row["id"]
            let name: String = row["name"]
            return MailSearchSuggestionItem(
                id: "mailbox:\(mailboxID)",
                title: name,
                detail: "Mailbox",
                insertion: quotedIfNeeded(name),
                replacementRange: context.replacementRange
            )
        }
    }

    private static func appendScopePredicates(
        scope: MailSearchSelectionScope,
        alias: String,
        predicates: inout [String],
        arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        if !scope.accountIDs.isEmpty {
            predicates.append(
                "\(alias).account_id IN (\(Array(repeating: "?", count: scope.accountIDs.count).joined(separator: ", ")))"
            )
            arguments.append(contentsOf: scope.accountIDs.map(\.rawValue))
        }
        if !scope.mailboxIDs.isEmpty {
            predicates.append("(" + scope.mailboxIDs.map { _ in
                "instr(' ' || \(alias).mailbox_ids || ' ', ' ' || ? || ' ') > 0"
            }.joined(separator: " OR ") + ")")
            arguments.append(contentsOf: scope.mailboxIDs.map(\.rawValue))
        }
    }

    private static func escapedLikePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || $0 == ":" || $0 == "\"" }
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func searchRevision(
        database: Database,
        scope: MailSearchSelectionScope,
        cursorCodec: MailSearchCursorCodec
    ) throws -> String {
        var sql = "SELECT account_id, revision, state FROM mail_search_state"
        var predicates: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []
        if !scope.accountIDs.isEmpty {
            predicates.append(
                "account_id IN (\(Array(repeating: "?", count: scope.accountIDs.count).joined(separator: ", ")))"
            )
            values.append(contentsOf: scope.accountIDs.map(\.rawValue))
        }
        if !scope.mailboxIDs.isEmpty {
            let mailboxPlaceholders = Array(repeating: "?", count: scope.mailboxIDs.count)
                .joined(separator: ", ")
            let membershipPredicates = scope.mailboxIDs.map { _ in
                "instr(' ' || d.mailbox_ids || ' ', ' ' || ? || ' ') > 0"
            }.joined(separator: " OR ")
            predicates.append("""
                account_id IN (
                    SELECT account_id FROM mailboxes WHERE id IN (\(mailboxPlaceholders))
                    UNION
                    SELECT DISTINCT d.account_id
                    FROM mail_search_documents d
                    WHERE \(membershipPredicates)
                )
                """)
            values.append(contentsOf: scope.mailboxIDs.map(\.rawValue))
            values.append(contentsOf: scope.mailboxIDs.map(\.rawValue))
        }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        }
        sql += " ORDER BY account_id"

        let rows = try Row.fetchAll(
            database,
            sql: sql,
            arguments: StatementArguments(values)
        )
        var entries: [String] = []
        for row in rows {
            let accountID: String = row["account_id"]
            let revision: Int64 = row["revision"]
            let state: String = row["state"]
            switch state {
            case MailSearchIndexState.ready.rawValue:
                break
            case MailSearchIndexState.preparing.rawValue, MailSearchIndexState.rebuilding.rawValue:
                throw MailSearchError.rebuilding
            case MailSearchIndexState.unavailable.rawValue:
                throw MailSearchError.unavailable
            default:
                throw MailSearchError.unavailable
            }
            entries.append("\(accountID.utf8.count):\(accountID)|\(revision)|\(state)")
        }
        return cursorCodec.revisionDigest(entries)
    }

    private static func makeHit(
        _ row: SearchRow,
        snippetMarkers: SQLiteMailSearchSnippetMarkers?
    ) throws -> MailMessageSearchHit {
        let snippet = safeSnippet(
            from: row.markedSnippet,
            markers: snippetMarkers,
            allowHighlights: !row.sourceContainsSnippetMarkers
        )
        return MailMessageSearchHit(
            stableID: row.stableID,
            messageID: MessageID(row.messageID),
            threadID: ThreadID(row.threadID.flatMap { $0.isEmpty ? nil : $0 } ?? row.stableID),
            accountID: AccountID(row.accountID),
            sender: EmailAddress(row.senderEmail),
            senderDisplayName: row.senderDisplayName,
            recipients: uniqueAddresses(row.toValue, row.ccValue, row.bccValue),
            subject: row.subject,
            sentAt: row.sentAt.map(Date.init(timeIntervalSince1970:)),
            snippet: snippet,
            isUnread: !row.isSeen,
            isFlagged: row.isFlagged,
            isDelegated: row.isDelegated,
            mailboxIDs: row.mailboxIDs.split(whereSeparator: \.isWhitespace).map {
                MailboxID(String($0))
            },
            hasAttachments: row.hasAttachments,
            hasDocuments: row.hasDocuments
        )
    }

    private static func uniqueAddresses(_ values: String...) -> [EmailAddress] {
        var seen: Set<String> = []
        return values
            .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .compactMap { value in
                let folded = value.lowercased()
                guard seen.insert(folded).inserted else { return nil }
                return EmailAddress(value)
            }
    }

    private static func safeSnippet(
        from markedText: String,
        markers: SQLiteMailSearchSnippetMarkers?,
        allowHighlights: Bool
    ) -> MailSearchSnippet {
        let recordSeparator: Character = "\u{001E}"
        let unitSeparator: Character = "\u{001F}"
        let raw = String(markedText.prefix(2_048))
        guard let markers else {
            let sanitized = String(raw.filter {
                $0 != recordSeparator && $0 != unitSeparator
            })
            let bounded = boundedUTF16(sanitized, maximum: 320)
            return (try? MailSearchSnippet(text: bounded.text, highlights: []))
                ?? (try! MailSearchSnippet(text: "", highlights: []))
        }
        var text = ""
        var highlights: [MailSearchTextRange] = []
        var activeStart: Int?
        var malformed = false

        var index = raw.startIndex
        while index < raw.endIndex {
            let remainder = raw[index...]
            if remainder.hasPrefix(markers.start) {
                if activeStart != nil { malformed = true }
                activeStart = text.utf16.count
                index = raw.index(index, offsetBy: markers.start.count)
            } else if remainder.hasPrefix(markers.end) {
                guard let start = activeStart else {
                    malformed = true
                    index = raw.index(index, offsetBy: markers.end.count)
                    continue
                }
                let length = text.utf16.count - start
                if length > 0 {
                    highlights.append(.init(location: start, length: length))
                } else {
                    malformed = true
                }
                activeStart = nil
                index = raw.index(index, offsetBy: markers.end.count)
            } else {
                let character = raw[index]
                if character == recordSeparator || character == unitSeparator {
                    malformed = true
                } else {
                    text.append(character)
                }
                index = raw.index(after: index)
            }
        }
        if activeStart != nil { malformed = true }

        let bounded = boundedUTF16(text, maximum: 320)
        if malformed {
            return (try? MailSearchSnippet(text: bounded.text, highlights: []))
                ?? (try! MailSearchSnippet(text: "", highlights: []))
        }
        let boundedHighlights = highlights.filter {
            allowHighlights &&
            $0.location >= 0 && $0.length > 0 && $0.location + $0.length <= bounded.utf16Length
        }
        return (try? MailSearchSnippet(text: bounded.text, highlights: boundedHighlights))
            ?? (try! MailSearchSnippet(text: bounded.text, highlights: []))
    }

    private static func boundedUTF16(
        _ value: String,
        maximum: Int
    ) -> (text: String, utf16Length: Int) {
        var result = ""
        var length = 0
        for character in value {
            let characterLength = character.utf16.count
            guard length + characterLength <= maximum else { break }
            result.append(character)
            length += characterLength
        }
        return (result, length)
    }
}

private struct SearchReadOutput: Sendable {
    let rows: [SearchRow]
    let conversationAggregates: [String: ConversationAggregateRow]
    let revision: String
    let snippetMarkers: SQLiteMailSearchSnippetMarkers?
}

private struct SearchRow: FetchableRecord, Sendable {
    let messageID: String
    let threadID: String?
    let accountID: String
    let sentAt: Double?
    let sortDate: Double
    let senderEmail: String
    let senderDisplayName: String?
    let toValue: String
    let ccValue: String
    let bccValue: String
    let subject: String
    let mailboxIDs: String
    let isSeen: Bool
    let isFlagged: Bool
    let isDelegated: Bool
    let hasAttachments: Bool
    let hasDocuments: Bool
    let exactTier: Int
    let lexicalScore: Double
    let markedSnippet: String
    let sourceContainsSnippetMarkers: Bool
    let conversationID: String
    let conversationActivity: Double
    let matchingMessageCount: Int
    let stableID: String

    var conversationKey: String {
        conversationID
    }

    init(row: Row) throws {
        messageID = row["message_id"]
        threadID = row["thread_id"]
        accountID = row["account_id"]
        sentAt = row["sent_at"]
        sortDate = row["sort_date"]
        senderEmail = row["sender_email"]
        senderDisplayName = row["sender_display_name"]
        toValue = row["to_value"]
        ccValue = row["cc_value"]
        bccValue = row["bcc_value"]
        subject = row["subject"]
        mailboxIDs = row["mailbox_ids"]
        isSeen = row["is_seen"]
        isFlagged = row["is_flagged"]
        isDelegated = row["is_delegated"]
        hasAttachments = row["has_attachments"]
        hasDocuments = row["has_documents"]
        exactTier = row["exact_tier"]
        lexicalScore = row["lexical_score"]
        markedSnippet = row["marked_snippet"]
        sourceContainsSnippetMarkers = row["source_contains_snippet_markers"]
        if row.columnNames.contains("conversation_id") {
            stableID = row["stable_id"]
            conversationID = row["conversation_id"]
            conversationActivity = row["conversation_activity"]
            matchingMessageCount = row["matching_message_count"]
        } else {
            stableID = MailSearchStableIdentity.message(
                accountID: AccountID(accountID),
                messageID: MessageID(messageID)
            )
            conversationID = messageID
            conversationActivity = sortDate
            matchingMessageCount = 1
        }
    }
}

private struct ConversationAggregateRow: FetchableRecord, Sendable {
    let accountID: String
    let conversationID: String
    let latestActivity: Double
    let totalMessageCount: Int
    let unreadMessageCount: Int
    let hasAttachments: Bool
    let hasDocuments: Bool
    let participants: [String]

    var key: String {
        conversationID
    }

    init(row: Row) throws {
        accountID = row["account_id"]
        conversationID = row["conversation_id"]
        latestActivity = row["latest_activity"]
        totalMessageCount = row["total_message_count"]
        unreadMessageCount = row["unread_message_count"]
        hasAttachments = row["has_attachments"]
        hasDocuments = row["has_documents"]

        var values = Self.jsonStrings(row: row, column: "sender_names")
        values.append(contentsOf: Self.jsonStrings(row: row, column: "sender_emails"))
        for column in ["to_values", "cc_values", "bcc_values"] {
            values.append(contentsOf: Self.jsonStrings(row: row, column: column).flatMap {
                $0.split(whereSeparator: \.isWhitespace).map(String.init)
            })
        }
        var seen: Set<String> = []
        participants = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func jsonStrings(row: Row, column: String) -> [String] {
        let value: String = row[column]
        return (try? JSONDecoder().decode([String?].self, from: Data(value.utf8)))?
            .compactMap { $0 } ?? []
    }
}

private struct SuggestionContext: Sendable {
    let replacementRange: MailSearchTextRange
    let fragment: String
    let activeField: String?

    var acceptsPeople: Bool {
        guard let activeField else { return true }
        return ["from", "to", "cc", "bcc", "participants"].contains(activeField)
    }

    init(request: MailSearchSuggestionRequest) {
        let source = request.query as NSString
        let supplied = request.activeRange
        if let supplied,
           supplied.location >= 0,
           supplied.length >= 0,
           supplied.location <= source.length,
           supplied.length <= source.length - supplied.location {
            let requested = NSRange(location: supplied.location, length: supplied.length)
            let composed = source.rangeOfComposedCharacterSequences(for: requested)
            replacementRange = .init(location: composed.location, length: composed.length)
        } else {
            var start = source.length
            while start > 0 {
                let scalar = source.character(at: start - 1)
                let isWhitespace = UnicodeScalar(scalar).map {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                } ?? false
                if scalar == 0x3A || scalar == 0x28 || scalar == 0x29
                    || isWhitespace {
                    break
                }
                start -= 1
            }
            replacementRange = .init(location: start, length: source.length - start)
        }
        fragment = source.substring(
            with: NSRange(location: replacementRange.location, length: replacementRange.length)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        activeField = MailSearchQueryParser.canonicalField(
            containingUTF16Range: replacementRange,
            in: request.query
        )
    }
}
