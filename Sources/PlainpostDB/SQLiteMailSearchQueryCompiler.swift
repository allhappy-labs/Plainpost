import Foundation
import GRDB
import PlainpostCore

package struct SQLiteMailSearchCursorBoundary: Equatable, Sendable {
    package let exactTier: Int
    package let lexicalScore: Double
    package let sortDate: Double
    package let stableID: String
    package let activityDate: Double
    package let conversationID: String

    package init(
        exactTier: Int,
        lexicalScore: Double,
        sortDate: Double,
        stableID: String,
        activityDate: Double? = nil,
        conversationID: String? = nil
    ) {
        self.exactTier = exactTier
        self.lexicalScore = lexicalScore
        self.sortDate = sortDate
        self.stableID = stableID
        self.activityDate = activityDate ?? sortDate
        self.conversationID = conversationID ?? stableID
    }
}

package struct SQLiteMailSearchSnippetMarkers: Equatable, Sendable {
    package let start: String
    package let end: String

    package init(nonce: String) {
        let token = String(nonce.unicodeScalars.lazy.compactMap { scalar -> Character? in
            guard scalar.isASCII,
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
            else { return nil }
            return Character(String(scalar).lowercased())
        }.prefix(64))
        let boundedToken = token.isEmpty ? "marker" : token
        start = "\u{001E}plainpost-search-\(boundedToken)-start["
        end = "]plainpost-search-\(boundedToken)-end\u{001F}"
    }
}

package struct SQLiteMailSearchCompiledQuery: Sendable {
    package let sql: String
    package let arguments: StatementArguments
    package let ftsQuery: String?
    package let fingerprintInput: String
    package let cursorSortDescriptors: [String]
}

package struct SQLiteMailSearchQueryCompiler: Sendable {
    package static let bm25Weights: [Double] = [
        8.0, 4.0, 4.0, 4.0, 10.0, 6.0, 3.0, 1.0, 8.0, 1.0,
    ]

    package init() {}

    package func compile(
        _ parsed: MailSearchParsedQuery,
        request: MailSearchRequest,
        cursor: SQLiteMailSearchCursorBoundary? = nil,
        snippetMarkers: SQLiteMailSearchSnippetMarkers
    ) throws -> SQLiteMailSearchCompiledQuery {
        try request.validate()
        let positiveText = parsed.expression.positiveTextLeaves()
        let reusesSingleFTSCandidateSet = positiveText.count == 1
            && parsed.expression.textLeafCount == 1
        var predicateCompiler = PredicateCompiler(
            reusesSingleFTSCandidateSet: reusesSingleFTSCandidateSet
        )
        let expressionPredicate = predicateCompiler.compile(parsed.expression)
        var basePredicates = ["d.is_deleted = 0"]
        if !parsed.expression.containsPositiveTrashLocation {
            basePredicates.append("d.is_trash = 0")
        }

        var scopeArguments: [(any DatabaseValueConvertible)?] = []
        if !request.scope.accountIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: request.scope.accountIDs.count)
                .joined(separator: ", ")
            basePredicates.append("d.account_id IN (\(placeholders))")
            scopeArguments.append(contentsOf: request.scope.accountIDs.map(\.rawValue))
        }
        if !request.scope.mailboxIDs.isEmpty {
            let predicates = request.scope.mailboxIDs.map { _ in
                "instr(' ' || d.mailbox_ids || ' ', ' ' || ? || ' ') > 0"
            }
            basePredicates.append("(\(predicates.joined(separator: " OR ")))")
            scopeArguments.append(contentsOf: request.scope.mailboxIDs.map(\.rawValue))
        }
        basePredicates.append(expressionPredicate)

        let ftsQuery = positiveText.isEmpty
            ? nil
            : positiveText.map(\.ftsExpression).joined(separator: " OR ")
        let exact = exactTierSQL(for: positiveText)
        let recencySQL = Self.recencySQL(column: "sort_date")

        let selectedColumns = """
            d.message_id, d.thread_id, d.account_id, d.sent_at, d.sort_date,
            d.sender_email, d.sender_display_name, d.to_value, d.cc_value, d.bcc_value,
            d.subject, d.preview, d.mailbox_ids, d.is_seen, d.is_flagged, d.is_delegated,
            d.has_attachments, d.has_documents
            """
        let ftsScoreCTE: String
        let ftsScoreJoin: String
        let lexicalSQL: String
        var lexicalArguments: [(any DatabaseValueConvertible)?] = []
        if let ftsQuery {
            ftsScoreCTE = """
                fts_scores AS MATERIALIZED (
                    SELECT
                        rowid,
                        -bm25(mail_search_fts, \(Self.bm25Weights.map { String($0) }.joined(separator: ", "))) AS raw_lexical_score
                    FROM mail_search_fts
                    WHERE mail_search_fts MATCH ?
                ),
                """
            ftsScoreJoin = "LEFT JOIN fts_scores AS fts_score ON fts_score.rowid = d.rowid"
            lexicalSQL = """
                COALESCE(fts_score.raw_lexical_score, 0.0)
                """
            lexicalArguments.append(ftsQuery)
        } else {
            ftsScoreCTE = ""
            ftsScoreJoin = ""
            lexicalSQL = "0.0"
        }

        let cursorClause = keysetClause(cursor, mode: request.mode)
        let markedSnippetSQL: String
        var snippetArguments: [(any DatabaseValueConvertible)?] = []
        let sourceMarkerCollisionSQL: String
        var sourceMarkerCollisionArguments: [(any DatabaseValueConvertible)?] = []
        if let ftsQuery {
            markedSnippetSQL = """
                COALESCE((
                    SELECT snippet(
                        mail_search_fts,
                        -1,
                        ?,
                        ?,
                        ' … ',
                        24
                    )
                    FROM mail_search_fts
                    WHERE mail_search_fts.rowid = w.rowid AND mail_search_fts MATCH ?
                ), substr(w.preview, 1, 320))
                """
            snippetArguments.append(snippetMarkers.start)
            snippetArguments.append(snippetMarkers.end)
            snippetArguments.append(ftsQuery)

            let sourceColumns = [
                "sender", "to_value", "cc_value", "bcc_value", "subject", "filenames",
                "labels", "mailbox_names", "identifiers", "body_text",
            ]
            let collisionPredicates = sourceColumns.flatMap { column in
                [
                    "instr(source.\(column), ?) > 0",
                    "instr(source.\(column), ?) > 0",
                ]
            }
            sourceMarkerCollisionSQL = """
                EXISTS (
                    SELECT 1
                    FROM mail_search_documents source
                    WHERE source.rowid = w.rowid
                      AND (\(collisionPredicates.joined(separator: " OR ")))
                )
                """
            for _ in sourceColumns {
                sourceMarkerCollisionArguments.append(snippetMarkers.start)
                sourceMarkerCollisionArguments.append(snippetMarkers.end)
            }
        } else {
            markedSnippetSQL = "substr(w.preview, 1, 320)"
            sourceMarkerCollisionSQL = "0"
        }

        let sql: String
        let cursorSortDescriptors: [String]
        switch request.mode {
        case .messages:
            sql = """
                WITH \(ftsScoreCTE) scored AS (
                    SELECT
                        d.rowid,
                        \(selectedColumns),
                        \(exact.sql) AS exact_tier,
                        \(lexicalSQL) AS raw_lexical_score
                    FROM mail_search_documents d
                    \(ftsScoreJoin)
                    WHERE \(basePredicates.map { "(\($0))" }.joined(separator: " AND "))
                ), ranked AS (
                    SELECT
                        scored.*,
                        CASE
                            WHEN raw_lexical_score > 0.0
                            THEN raw_lexical_score / (1.0 + raw_lexical_score)
                            ELSE 0.0
                        END AS lexical_score,
                        \(recencySQL) AS recency_score
                    FROM scored
                ), winners AS (
                    SELECT * FROM ranked
                    \(cursorClause.sql)
                    ORDER BY exact_tier DESC, lexical_score DESC, recency_score DESC,
                             sort_date DESC, message_id ASC
                    LIMIT ?
                )
                SELECT
                    w.*,
                    \(markedSnippetSQL) AS marked_snippet,
                    \(sourceMarkerCollisionSQL) AS source_contains_snippet_markers
                FROM winners w
                ORDER BY w.exact_tier DESC, w.lexical_score DESC, w.recency_score DESC,
                         w.sort_date DESC, w.message_id ASC
                """
            cursorSortDescriptors = [
                "exact_tier DESC",
                "lexical_score DESC",
                "recency_score DESC",
                "sort_date DESC",
                "message_id ASC",
            ]
        case .conversations:
            let conversationID = Self.conversationIdentitySQL(alias: "d")
            let messageStableID = Self.stableMessageIdentitySQL(alias: "d")
            sql = """
                WITH \(ftsScoreCTE) scored AS (
                    SELECT
                        d.rowid,
                        \(selectedColumns),
                        \(conversationID) AS conversation_id,
                        \(messageStableID) AS stable_id,
                        \(messageStableID) AS message_stable_id,
                        \(exact.sql) AS exact_tier,
                        \(lexicalSQL) AS raw_lexical_score
                    FROM mail_search_documents d
                    \(ftsScoreJoin)
                    WHERE \(basePredicates.map { "(\($0))" }.joined(separator: " AND "))
                ), ranked_candidates AS (
                    SELECT
                        scored.*,
                        CASE
                            WHEN raw_lexical_score > 0.0
                            THEN raw_lexical_score / (1.0 + raw_lexical_score)
                            ELSE 0.0
                        END AS lexical_score,
                        \(recencySQL) AS recency_score
                    FROM scored
                ), grouped_candidates AS (
                    SELECT
                        ranked_candidates.*,
                        ROW_NUMBER() OVER (
                            PARTITION BY account_id, conversation_id
                            ORDER BY exact_tier DESC, lexical_score DESC, recency_score DESC,
                                     sort_date DESC, message_stable_id ASC
                        ) AS match_position,
                        COUNT(*) OVER (
                            PARTITION BY account_id, conversation_id
                        ) AS matching_message_count
                    FROM ranked_candidates
                ), winning_conversations AS (
                    SELECT
                        grouped_candidates.*,
                        CASE
                            WHEN NULLIF(grouped_candidates.thread_id, '') IS NULL
                            THEN grouped_candidates.sort_date
                            ELSE COALESCE((
                                SELECT MAX(activity.sort_date)
                                FROM mail_search_documents activity
                                WHERE activity.account_id = grouped_candidates.account_id
                                  AND activity.thread_id = grouped_candidates.thread_id
                                  AND activity.is_deleted = 0
                            ), grouped_candidates.sort_date)
                        END AS conversation_activity
                    FROM grouped_candidates
                    WHERE match_position = 1
                ), winners AS (
                    SELECT * FROM winning_conversations
                    \(cursorClause.sql)
                    ORDER BY exact_tier DESC, lexical_score DESC, recency_score DESC,
                             sort_date DESC, conversation_activity DESC,
                             conversation_id ASC
                    LIMIT ?
                )
                SELECT
                    w.*,
                    \(markedSnippetSQL) AS marked_snippet,
                    \(sourceMarkerCollisionSQL) AS source_contains_snippet_markers
                FROM winners w
                ORDER BY w.exact_tier DESC, w.lexical_score DESC, w.recency_score DESC,
                         w.sort_date DESC, w.conversation_activity DESC,
                         w.conversation_id ASC
                """
            cursorSortDescriptors = [
                "exact_tier DESC",
                "lexical_score DESC",
                "recency_score DESC",
                "sort_date DESC",
                "conversation_activity DESC",
                "conversation_id ASC",
            ]
        }

        let values = lexicalArguments
            + exact.arguments
            + scopeArguments
            + predicateCompiler.arguments
            + cursorClause.arguments
            + [request.limit + 1]
            + snippetArguments
            + sourceMarkerCollisionArguments

        return SQLiteMailSearchCompiledQuery(
            sql: sql,
            arguments: StatementArguments(values),
            ftsQuery: ftsQuery,
            fingerprintInput: fingerprintInput(parsed: parsed, request: request),
            cursorSortDescriptors: cursorSortDescriptors
        )
    }

    package static func recencyScore(for sortDate: Double) -> Double {
        guard sortDate > 0 else { return 0 }
        return min(1, sortDate / 4_102_444_800)
    }

    private static func recencySQL(column: String) -> String {
        "CASE WHEN \(column) <= 0.0 THEN 0.0 WHEN \(column) >= 4102444800.0 THEN 1.0 ELSE \(column) / 4102444800.0 END"
    }

    private func keysetClause(
        _ cursor: SQLiteMailSearchCursorBoundary?,
        mode: MailSearchMode
    ) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        guard let cursor else { return ("", []) }
        let recency = Self.recencyScore(for: cursor.sortDate)
        let scorePrefix: [(any DatabaseValueConvertible)?] = [
            cursor.exactTier,
            cursor.exactTier, cursor.lexicalScore,
            cursor.exactTier, cursor.lexicalScore, recency,
            cursor.exactTier, cursor.lexicalScore, recency, cursor.sortDate,
        ]
        switch mode {
        case .messages:
            return (
                """
                WHERE
                    exact_tier < ?
                    OR (exact_tier = ? AND lexical_score < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score = ? AND sort_date < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score = ? AND sort_date = ? AND message_id > ?)
                """,
                scorePrefix + [
                    cursor.exactTier, cursor.lexicalScore, recency, cursor.sortDate,
                    cursor.stableID,
                ]
            )
        case .conversations:
            return (
                """
                WHERE
                    exact_tier < ?
                    OR (exact_tier = ? AND lexical_score < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score = ? AND sort_date < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score = ? AND sort_date = ? AND conversation_activity < ?)
                    OR (exact_tier = ? AND lexical_score = ? AND recency_score = ? AND sort_date = ? AND conversation_activity = ? AND conversation_id > ?)
                """,
                scorePrefix + [
                    cursor.exactTier, cursor.lexicalScore, recency, cursor.sortDate,
                    cursor.activityDate,
                    cursor.exactTier, cursor.lexicalScore, recency, cursor.sortDate,
                    cursor.activityDate, cursor.conversationID,
                ]
            )
        }
    }

    package static func conversationIdentitySQL(alias: String) -> String {
        """
        CASE
            WHEN NULLIF(\(alias).thread_id, '') IS NULL
            THEN \(stableMessageIdentitySQL(alias: alias))
            ELSE '\(MailSearchStableIdentity.threadPrefix)' || hex(CAST(\(alias).account_id AS BLOB))
                 || '|' || hex(CAST(\(alias).thread_id AS BLOB))
        END
        """
    }

    package static func stableMessageIdentitySQL(alias: String) -> String {
        """
        '\(MailSearchStableIdentity.messagePrefix)' || hex(CAST(\(alias).account_id AS BLOB))
        || '|' || hex(CAST(\(alias).message_id AS BLOB))
        """
    }

    private func exactTierSQL(
        for leaves: [TextLeaf]
    ) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        var tiers: [[(sql: String, value: String)]] = [[], [], [], []]
        for leaf in leaves {
            switch leaf.field {
            case .subject:
                tiers[3].append(("lower(d.subject) = lower(?)", leaf.value))
            case .from:
                tiers[2].append(("(lower(d.sender_email) = lower(?) OR lower(COALESCE(d.sender_display_name, '')) = lower(?))", leaf.value))
            case .to:
                tiers[2].append(("lower(d.to_value) = lower(?)", leaf.value))
            case .cc:
                tiers[2].append(("lower(d.cc_value) = lower(?)", leaf.value))
            case .bcc:
                tiers[2].append(("lower(d.bcc_value) = lower(?)", leaf.value))
            case .participants:
                tiers[2].append(("(lower(d.sender_email) = lower(?) OR lower(COALESCE(d.sender_display_name, '')) = lower(?) OR lower(d.to_value) = lower(?) OR lower(d.cc_value) = lower(?) OR lower(d.bcc_value) = lower(?))", leaf.value))
            case .filename:
                tiers[1].append(("lower(d.filenames) = lower(?)", leaf.value))
            case .mailbox:
                tiers[1].append(("lower(d.mailbox_names) = lower(?)", leaf.value))
            case nil:
                tiers[3].append(("lower(d.subject) = lower(?)", leaf.value))
                tiers[2].append(("(lower(d.sender_email) = lower(?) OR lower(COALESCE(d.sender_display_name, '')) = lower(?))", leaf.value))
                tiers[1].append(("lower(d.filenames) = lower(?)", leaf.value))
            }
        }

        var cases: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        for tier in stride(from: 3, through: 1, by: -1) {
            guard !tiers[tier].isEmpty else { continue }
            cases.append("WHEN \(tiers[tier].map(\.sql).joined(separator: " OR ")) THEN \(tier)")
            for condition in tiers[tier] {
                let placeholderCount = condition.sql.reduce(into: 0) { count, character in
                    if character == "?" { count += 1 }
                }
                arguments.append(contentsOf: Array(repeating: condition.value, count: placeholderCount))
            }
        }
        guard !cases.isEmpty else { return ("0", []) }
        return ("CASE \(cases.joined(separator: " ")) ELSE 0 END", arguments)
    }

    package func fingerprintInput(
        parsed: MailSearchParsedQuery,
        request: MailSearchRequest
    ) -> String {
        let accounts = request.scope.accountIDs.map(\.rawValue)
        let mailboxes = request.scope.mailboxIDs.map(\.rawValue)
        return [
            "query:\(parsed.canonicalQuery.utf8.count):\(parsed.canonicalQuery)",
            "mode:\(request.mode.rawValue)",
            "accounts:\(accounts.map { "\($0.utf8.count):\($0)" }.joined(separator: ","))",
            "mailboxes:\(mailboxes.map { "\($0.utf8.count):\($0)" }.joined(separator: ","))",
            "limit:\(request.limit)",
        ].joined(separator: "|")
    }
}

private struct PredicateCompiler {
    let reusesSingleFTSCandidateSet: Bool
    var arguments: [(any DatabaseValueConvertible)?] = []

    mutating func compile(
        _ expression: MailSearchQueryExpression,
        field: MailSearchTextField? = nil
    ) -> String {
        switch expression {
        case .matchAll:
            return "1"
        case .term(let value, let prefix):
            return textPredicate(value: value, prefix: prefix, field: field)
        case .phrase(let value):
            return textPredicate(value: value, prefix: false, field: field)
        case .field(let selectedField, let nested):
            return compile(nested, field: selectedField)
        case .content(.attachment):
            return "d.has_attachments = 1"
        case .content(.document):
            return "d.has_documents = 1"
        case .state(.unread):
            return "d.is_seen = 0"
        case .state(.read):
            return "d.is_seen = 1"
        case .state(.flagged):
            return "d.is_flagged = 1"
        case .state(.delegated):
            return "d.is_delegated = 1"
        case .location(.inbox):
            return "d.is_inbox = 1"
        case .location(.sent):
            return "d.is_sent = 1"
        case .location(.trash):
            return "d.is_trash = 1"
        case .date(let interval):
            var predicates: [String] = []
            if let lowerBound = interval.lowerBound {
                predicates.append("d.sort_date >= ?")
                arguments.append(lowerBound.timeIntervalSince1970)
            }
            if let upperBound = interval.upperBound {
                predicates.append("d.sort_date < ?")
                arguments.append(upperBound.timeIntervalSince1970)
            }
            return predicates.isEmpty ? "1" : predicates.map { "(\($0))" }.joined(separator: " AND ")
        case .all(let expressions):
            return combine(expressions, separator: "AND", field: field, empty: "1")
        case .any(let expressions):
            return combine(expressions, separator: "OR", field: field, empty: "0")
        case .not(let nested):
            return "NOT (\(compile(nested, field: field)))"
        }
    }

    private mutating func combine(
        _ expressions: [MailSearchQueryExpression],
        separator: String,
        field: MailSearchTextField?,
        empty: String
    ) -> String {
        guard !expressions.isEmpty else { return empty }
        return expressions.map { "(\(compile($0, field: field)))" }.joined(separator: " \(separator) ")
    }

    private mutating func textPredicate(
        value: String,
        prefix: Bool,
        field: MailSearchTextField?
    ) -> String {
        if reusesSingleFTSCandidateSet {
            return "fts_score.rowid IS NOT NULL"
        }
        arguments.append(TextLeaf(value: value, prefix: prefix, field: field).ftsExpression)
        return "d.rowid IN (SELECT rowid FROM mail_search_fts WHERE mail_search_fts MATCH ?)"
    }
}

private struct TextLeaf {
    let value: String
    let prefix: Bool
    let field: MailSearchTextField?

    var ftsExpression: String {
        let token = SQLiteMailSearchQueryCompiler.ftsToken(value, prefix: prefix)
        guard let field else { return token }
        return "\(field.ftsColumnSelector) : \(token)"
    }
}

private extension SQLiteMailSearchQueryCompiler {
    static func ftsToken(_ value: String, prefix: Bool) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"\(prefix ? "*" : "")"
    }
}

private extension MailSearchTextField {
    var ftsColumnSelector: String {
        switch self {
        case .from: "sender"
        case .to: "to_value"
        case .cc: "cc_value"
        case .bcc: "bcc_value"
        case .participants: "{sender to_value cc_value bcc_value}"
        case .subject: "subject"
        case .filename: "filenames"
        case .mailbox: "mailbox_names"
        }
    }
}

private extension MailSearchQueryExpression {
    var textLeafCount: Int {
        switch self {
        case .matchAll:
            0
        case .term, .phrase:
            1
        case .field(_, let expression), .not(let expression):
            expression.textLeafCount
        case .all(let expressions), .any(let expressions):
            expressions.reduce(0) { $0 + $1.textLeafCount }
        case .content, .state, .location, .date:
            0
        }
    }

    var containsPositiveTrashLocation: Bool {
        containsPositiveTrashLocation(negated: false)
    }

    func containsPositiveTrashLocation(negated: Bool) -> Bool {
        switch self {
        case .matchAll:
            false
        case .location(.trash):
            !negated
        case .field(_, let expression):
            expression.containsPositiveTrashLocation(negated: negated)
        case .all(let expressions), .any(let expressions):
            expressions.contains { $0.containsPositiveTrashLocation(negated: negated) }
        case .not(let expression):
            expression.containsPositiveTrashLocation(negated: !negated)
        default:
            false
        }
    }

    func positiveTextLeaves(
        field: MailSearchTextField? = nil,
        negated: Bool = false
    ) -> [TextLeaf] {
        switch self {
        case .matchAll:
            []
        case .term(let value, let prefix):
            negated ? [] : [TextLeaf(value: value, prefix: prefix, field: field)]
        case .phrase(let value):
            negated ? [] : [TextLeaf(value: value, prefix: false, field: field)]
        case .field(let selectedField, let expression):
            expression.positiveTextLeaves(field: selectedField, negated: negated)
        case .all(let expressions), .any(let expressions):
            expressions.flatMap { $0.positiveTextLeaves(field: field, negated: negated) }
        case .not(let expression):
            expression.positiveTextLeaves(field: field, negated: !negated)
        case .content, .state, .location, .date:
            []
        }
    }
}
