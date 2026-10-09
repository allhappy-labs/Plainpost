import Foundation

public struct MailSearchSuggestionContext: Equatable, Sendable {
    public let replacementRange: MailSearchTextRange
    public let canonicalField: String?

    public init(replacementRange: MailSearchTextRange, canonicalField: String?) {
        self.replacementRange = replacementRange
        self.canonicalField = canonicalField
    }
}

public struct MailSearchQueryParser: Sendable {
    public static let maximumQueryCharacters = 2_048
    public static let maximumTerms = 64
    public static let maximumClauses = 32
    public static let maximumDepth = 8
    public static let maximumQueryUTF8Bytes = maximumQueryCharacters * 4
    public static let maximumAggregateExpressionCount = maximumTerms + maximumClauses
    public static let maximumExpressionNodeCount = maximumQueryCharacters + 1
    public static let minimumSupportedDate = Date(timeIntervalSince1970: -62_135_596_800)
    public static let maximumSupportedDateExclusive = Date(timeIntervalSince1970: 253_402_300_800)

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func parse(_ rawQuery: String, now: Date = Date()) throws -> MailSearchParsedQuery {
        guard rawQuery.utf8.prefix(Self.maximumQueryUTF8Bytes + 1).count
            <= Self.maximumQueryUTF8Bytes else {
            throw MailSearchError.requestTooLarge(maximum: Self.maximumQueryCharacters)
        }
        guard rawQuery.prefix(Self.maximumQueryCharacters + 1).count
            <= Self.maximumQueryCharacters else {
            throw MailSearchError.requestTooLarge(maximum: Self.maximumQueryCharacters)
        }

        let tokens = try MailSearchLexer(rawQuery).scan()
        var state = ParserState(tokens: tokens, now: now, calendar: calendar)
        guard !state.isAtEnd else {
            throw MailSearchError.invalidQuery(reason: "Query is empty.", range: nil)
        }
        let expression = try state.parseOr(depth: 0).normalized()
        try state.requireEnd()
        return MailSearchParsedQuery(
            expression: expression,
            tokens: MailSearchLexer.presentationTokens(from: tokens),
            canonicalQuery: expression.canonicalDescription
        )
    }

    public func parse(_ request: MailSearchRequest, now: Date = Date()) throws -> MailSearchParsedQuery {
        try request.validate()
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MailSearchParsedQuery(
                expression: .matchAll,
                tokens: [],
                canonicalQuery: MailSearchQueryExpression.matchAll.canonicalDescription
            )
        }
        return try parse(request.query, now: now)
    }

    public static func suggestionContext(
        in rawQuery: String,
        selection: MailSearchTextRange
    ) -> MailSearchSuggestionContext? {
        guard rawQuery.utf8.prefix(Self.maximumQueryUTF8Bytes + 1).count
                <= Self.maximumQueryUTF8Bytes,
              rawQuery.prefix(Self.maximumQueryCharacters + 1).count
                <= Self.maximumQueryCharacters else {
            return nil
        }
        let utf16Count = rawQuery.utf16.count
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= utf16Count,
              selection.length <= utf16Count - selection.location,
              let tokens = try? MailSearchLexer(rawQuery).scan(allowUnclosedPhrase: true)
        else {
            return nil
        }

        let source = rawQuery as NSString
        let normalizedSelection = normalizedSelection(selection, in: rawQuery)
        let activeToken = tokens.first { token in
            token.kind != .end && contains(normalizedSelection, in: token.range)
        }
        let activeReplacementRange = activeToken.map {
            replacementRange(for: $0, in: source)
        } ?? normalizedSelection

        for index in tokens.indices where index + 1 < tokens.count {
            guard case .word(let candidate) = tokens[index].kind,
                  tokens[index + 1].kind == .colon,
                  let canonical = MailSearchFieldRegistry.canonicalName(for: candidate) else {
                continue
            }

            let colonEnd = tokens[index + 1].range.location + tokens[index + 1].range.length
            let valueIndex = index + 2
            let nextToken = tokens[valueIndex]
            if normalizedSelection.length == 0,
               normalizedSelection.location >= colonEnd,
               normalizedSelection.location <= nextToken.range.location {
                return MailSearchSuggestionContext(
                    replacementRange: normalizedSelection,
                    canonicalField: canonical
                )
            }

            let valueTokenBounds = fieldValueTokenBounds(startingAt: valueIndex, in: tokens)
            if valueTokenBounds.contains(where: { tokenIndex in
                contains(normalizedSelection, in: tokens[tokenIndex].range)
            }) {
                return MailSearchSuggestionContext(
                    replacementRange: activeReplacementRange,
                    canonicalField: canonical
                )
            }
        }

        if activeToken != nil {
            return MailSearchSuggestionContext(
                replacementRange: activeReplacementRange,
                canonicalField: nil
            )
        }

        return MailSearchSuggestionContext(
            replacementRange: normalizedSelection,
            canonicalField: nil
        )
    }

    public static func isSupportedDate(_ date: Date, allowsUpperExclusive: Bool = false) -> Bool {
        let value = date.timeIntervalSince1970
        let lower = minimumSupportedDate.timeIntervalSince1970
        let upper = maximumSupportedDateExclusive.timeIntervalSince1970
        return value.isFinite && value >= lower && (allowsUpperExclusive ? value <= upper : value < upper)
    }

    package static func canonicalField(
        containingUTF16Range range: MailSearchTextRange,
        in rawQuery: String
    ) -> String? {
        suggestionContext(in: rawQuery, selection: range)?.canonicalField
    }

    private static func replacementRange(
        for token: MailSearchLexer.Token,
        in source: NSString
    ) -> MailSearchTextRange {
        guard case .phrase = token.kind else { return token.range }
        let tokenEnd = token.range.location + token.range.length
        let contentStart = min(tokenEnd, token.range.location + 1)
        let hasClosingQuote = token.range.length >= 2
            && source.character(at: tokenEnd - 1) == 0x22
        let contentEnd = max(contentStart, tokenEnd - (hasClosingQuote ? 1 : 0))
        return MailSearchTextRange(
            location: contentStart,
            length: contentEnd - contentStart
        )
    }

    private static func normalizedSelection(
        _ selection: MailSearchTextRange,
        in source: String
    ) -> MailSearchTextRange {
        let requested = NSRange(location: selection.location, length: selection.length)
        guard selection.length == 0 else {
            let composed = (source as NSString).rangeOfComposedCharacterSequences(for: requested)
            return .init(location: composed.location, length: composed.length)
        }

        var boundaries = Set([0])
        var offset = 0
        for character in source {
            offset += String(character).utf16.count
            boundaries.insert(offset)
        }
        guard !boundaries.contains(selection.location) else { return selection }
        let composed = (source as NSString).rangeOfComposedCharacterSequence(
            at: selection.location
        )
        return .init(location: composed.location, length: composed.length)
    }

    private static func fieldValueTokenBounds(
        startingAt start: Int,
        in tokens: [MailSearchLexer.Token]
    ) -> [Int] {
        guard start < tokens.count, tokens[start].kind != .end else { return [] }
        guard tokens[start].kind == .leftParenthesis else { return [start] }

        var depth = 0
        var result: [Int] = []
        for index in start..<tokens.count {
            let token = tokens[index]
            guard token.kind != .end else { break }
            result.append(index)
            switch token.kind {
            case .leftParenthesis:
                depth += 1
            case .rightParenthesis:
                depth -= 1
                if depth == 0 { return result }
            default:
                break
            }
        }
        return result
    }

    private static func contains(
        _ selection: MailSearchTextRange,
        in candidate: MailSearchTextRange
    ) -> Bool {
        let selectionEnd = selection.location + selection.length
        let candidateEnd = candidate.location + candidate.length
        return selection.location >= candidate.location && selectionEnd <= candidateEnd
    }
}

private struct MailSearchLexer {
    enum TokenKind: Equatable {
        case word(String)
        case phrase(String)
        case colon
        case leftParenthesis
        case rightParenthesis
        case minus
        case end
    }

    struct Token: Equatable {
        let kind: TokenKind
        let range: MailSearchTextRange
    }

    private let source: String

    init(_ source: String) {
        self.source = source
    }

    func scan(allowUnclosedPhrase: Bool = false) throws -> [Token] {
        var tokens: [Token] = []
        var index = source.startIndex

        while index < source.endIndex {
            if isIgnored(source[index]) {
                index = source.index(after: index)
                continue
            }

            let start = index
            switch source[index] {
            case ":":
                index = source.index(after: index)
                tokens.append(Token(kind: .colon, range: range(from: start, to: index)))
            case "(":
                index = source.index(after: index)
                tokens.append(Token(kind: .leftParenthesis, range: range(from: start, to: index)))
            case ")":
                index = source.index(after: index)
                tokens.append(Token(kind: .rightParenthesis, range: range(from: start, to: index)))
            case "-":
                index = source.index(after: index)
                tokens.append(Token(kind: .minus, range: range(from: start, to: index)))
            case "\"":
                index = source.index(after: index)
                var value = ""
                var foundClosingQuote = false
                while index < source.endIndex {
                    if source[index] == "\"" {
                        index = source.index(after: index)
                        foundClosingQuote = true
                        break
                    }
                    if source[index] == "\\" {
                        let escapeStart = index
                        index = source.index(after: index)
                        guard index < source.endIndex else {
                            throw MailSearchError.invalidQuery(
                                reason: "Quoted phrase has a dangling escape.",
                                range: range(from: escapeStart, to: source.endIndex)
                            )
                        }
                        let escapedCharacter = source[index]
                        guard escapedCharacter == "\\" || escapedCharacter == "\"" else {
                            throw MailSearchError.invalidQuery(
                                reason: "Quoted phrase contains an unsupported escape.",
                                range: range(
                                    from: escapeStart,
                                    to: source.index(after: index)
                                )
                            )
                        }
                        value.append(escapedCharacter)
                        index = source.index(after: index)
                        continue
                    }
                    if !isControl(source[index]) {
                        value.append(source[index])
                    }
                    index = source.index(after: index)
                }
                if !foundClosingQuote, !allowUnclosedPhrase {
                    throw MailSearchError.invalidQuery(
                        reason: "Quoted phrase is not closed.",
                        range: range(from: start, to: source.endIndex)
                    )
                }
                tokens.append(Token(
                    kind: .phrase(value.precomposedStringWithCanonicalMapping),
                    range: range(from: start, to: index)
                ))
            default:
                var value = ""
                while index < source.endIndex {
                    let character = source[index]
                    if isControl(character) {
                        index = source.index(after: index)
                        continue
                    }
                    if character.isWhitespace || isDelimiter(character) {
                        break
                    }
                    value.append(character)
                    index = source.index(after: index)
                }
                if !value.isEmpty {
                    tokens.append(Token(
                        kind: .word(value.precomposedStringWithCanonicalMapping),
                        range: range(from: start, to: index)
                    ))
                }
            }
        }

        let endLocation = source.utf16.count
        tokens.append(Token(
            kind: .end,
            range: .init(location: endLocation, length: 0)
        ))
        return tokens
    }

    static func presentationTokens(from tokens: [Token]) -> [MailSearchPresentationToken] {
        tokens.indices.compactMap { index in
            let token = tokens[index]
            let kind: MailSearchPresentationTokenKind
            let text: String
            switch token.kind {
            case .word(let value):
                text = value
                if index + 1 < tokens.count, tokens[index + 1].kind == .colon {
                    kind = .filter
                } else if ["and", "or", "not"].contains(fold(value)) {
                    kind = .boolean
                } else {
                    kind = .text
                }
            case .phrase(let value):
                kind = .phrase
                text = value
            case .colon:
                kind = .filter
                text = ":"
            case .leftParenthesis:
                kind = .grouping
                text = "("
            case .rightParenthesis:
                kind = .grouping
                text = ")"
            case .minus:
                kind = .boolean
                text = "-"
            case .end:
                return nil
            }
            return MailSearchPresentationToken(kind: kind, text: text, sourceRange: token.range)
        }
    }

    private func range(from start: String.Index, to end: String.Index) -> MailSearchTextRange {
        let location = source.utf16.distance(from: source.startIndex, to: start)
        let length = source.utf16.distance(from: start, to: end)
        return .init(location: location, length: length)
    }

    private func isIgnored(_ character: Character) -> Bool {
        character.isWhitespace || isControl(character)
    }

    private func isControl(_ character: Character) -> Bool {
        // Keep scalar membership explicit: Swift 6.4 Release builds miscompile the
        // bound method reference when it is also used by contains(where:) in this module.
        character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    }

    private func isDelimiter(_ character: Character) -> Bool {
        character == ":" || character == "(" || character == ")" || character == "\""
    }

    fileprivate static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct ParserState {
    private let tokens: [MailSearchLexer.Token]
    private let now: Date
    private let calendar: Calendar
    private var index = 0
    private var termCount = 0
    private var clauseCount = 0
    private var textFieldContextDepth = 0

    init(tokens: [MailSearchLexer.Token], now: Date, calendar: Calendar) {
        self.tokens = tokens
        self.now = now
        self.calendar = calendar
    }

    var isAtEnd: Bool {
        current.kind == .end
    }

    mutating func parseOr(depth: Int) throws -> MailSearchQueryExpression {
        var values = [try parseAnd(depth: depth)]
        while consumeKeyword("OR") {
            values.append(try parseAnd(depth: depth))
        }
        return values.count == 1 ? values[0] : .any(values)
    }

    mutating func parseAnd(depth: Int) throws -> MailSearchQueryExpression {
        var values = [try parseUnary(depth: depth)]
        while true {
            if consumeKeyword("AND") {
                values.append(try parseUnary(depth: depth))
            } else if canStartExpression {
                values.append(try parseUnary(depth: depth))
            } else {
                break
            }
        }
        return values.count == 1 ? values[0] : .all(values)
    }

    mutating func parseUnary(depth: Int) throws -> MailSearchQueryExpression {
        if consumeKeyword("NOT") || consumeMinus() {
            return .not(try parseUnary(depth: depth))
        }
        return try parsePrimary(depth: depth)
    }

    mutating func requireEnd() throws {
        guard isAtEnd else {
            throw invalid("Unexpected token.", at: current.range)
        }
    }

    private mutating func parsePrimary(depth: Int) throws -> MailSearchQueryExpression {
        let token = current
        switch token.kind {
        case .leftParenthesis:
            guard depth < MailSearchQueryParser.maximumDepth else {
                throw MailSearchError.invalidQuery(
                    reason: "Nesting is too deep; maximum is 8.",
                    range: nil
                )
            }
            advance()
            guard current.kind != .rightParenthesis else {
                throw invalid("Grouped expression is empty.", at: current.range)
            }
            let expression = try parseOr(depth: depth + 1)
            guard current.kind == .rightParenthesis else {
                throw invalid("Closing parenthesis is missing.", at: current.range)
            }
            advance()
            return expression
        case .phrase(let value):
            guard !value.isEmpty else {
                throw invalid("Search value is empty.", at: token.range)
            }
            advance()
            try recordTerm()
            return .phrase(value)
        case .word(let value):
            if peek.kind == .colon {
                return try parseField(name: value, nameRange: token.range, depth: depth)
            }
            let keyword = MailSearchLexer.fold(value)
            guard keyword != "and", keyword != "or" else {
                throw invalid("Boolean operator is missing an operand.", at: token.range)
            }
            advance()
            if keyword == "delegated", textFieldContextDepth == 0 {
                try recordClause()
                return .state(.delegated)
            }
            try recordTerm()
            return .term(value, prefix: true)
        case .end, .rightParenthesis, .colon, .minus:
            throw invalid("Expected a search expression.", at: token.range)
        }
    }

    private mutating func parseField(
        name: String,
        nameRange: MailSearchTextRange,
        depth: Int
    ) throws -> MailSearchQueryExpression {
        guard let canonicalName = MailSearchFieldRegistry.canonicalName(for: name) else {
            throw MailSearchError.unsupportedField(
                name: MailSearchLexer.fold(name),
                range: nameRange
            )
        }
        advance()
        advance()

        let valueToken = current
        guard valueToken.kind != .end,
              valueToken.kind != .rightParenthesis,
              valueToken.kind != .colon else {
            throw invalid("Structured field value is empty.", at: valueToken.range)
        }

        if let textField = MailSearchTextField(rawValue: canonicalName) {
            try recordClause()
            textFieldContextDepth += 1
            let expression: MailSearchQueryExpression
            do {
                expression = try parseUnary(depth: depth)
            } catch {
                textFieldContextDepth -= 1
                throw error
            }
            textFieldContextDepth -= 1
            guard expression.isTextOnly else {
                throw invalid("Text field contains a structured filter.", at: valueToken.range)
            }
            return .field(textField, expression)
        }

        guard case .word(let rawValue) = valueToken.kind else {
            throw unsupportedValue(field: canonicalName, token: valueToken)
        }
        advance()
        try recordClause()
        let value = MailSearchLexer.fold(rawValue)
        switch canonicalName {
        case "has":
            switch value {
            case "attachment", "attachments": return .content(.attachment)
            case "document", "documents": return .content(.document)
            default: throw unsupportedValue(field: canonicalName, token: valueToken)
            }
        case "with":
            switch value {
            case "attachment", "attachments": return .content(.attachment)
            case "document", "documents": return .content(.document)
            default: throw unsupportedValue(field: canonicalName, token: valueToken)
            }
        case "is":
            guard let filter = MailSearchStateFilter(rawValue: value) else {
                throw unsupportedValue(field: canonicalName, token: valueToken)
            }
            return .state(filter)
        case "in":
            guard let filter = MailSearchLocationFilter(rawValue: value) else {
                throw unsupportedValue(field: canonicalName, token: valueToken)
            }
            return .location(filter)
        case "since", "after", "before", "on", "date":
            return .date(try dateInterval(field: canonicalName, value: rawValue, token: valueToken))
        default:
            throw MailSearchError.unsupportedField(name: canonicalName, range: nameRange)
        }
    }

    private func dateInterval(
        field: String,
        value: String,
        token: MailSearchLexer.Token
    ) throws -> MailSearchDateInterval {
        switch field {
        case "since":
            if let date = namedDay(value) {
                return .init(lowerBound: date, upperBound: nil)
            }
            guard let boundary = relativeBoundary(value) else {
                throw unsupportedValue(field: field, token: token)
            }
            return .init(lowerBound: boundary, upperBound: nil)
        case "after":
            guard let day = namedDay(value),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  MailSearchQueryParser.isSupportedDate(nextDay) else {
                throw unsupportedValue(field: field, token: token)
            }
            return .init(lowerBound: nextDay, upperBound: nil)
        case "before":
            guard let day = namedDay(value) else {
                throw unsupportedValue(field: field, token: token)
            }
            return .init(lowerBound: nil, upperBound: day)
        case "on":
            guard let day = namedDay(value),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  MailSearchQueryParser.isSupportedDate(nextDay, allowsUpperExclusive: true) else {
                throw unsupportedValue(field: field, token: token)
            }
            return .init(lowerBound: day, upperBound: nextDay)
        case "date":
            let parts = value.components(separatedBy: "..")
            guard parts.count == 2,
                  let start = isoDay(parts[0]),
                  let end = isoDay(parts[1]),
                  start <= end,
                  let upper = calendar.date(byAdding: .day, value: 1, to: end),
                  MailSearchQueryParser.isSupportedDate(upper, allowsUpperExclusive: true) else {
                throw unsupportedValue(field: field, token: token)
            }
            return .init(lowerBound: start, upperBound: upper)
        default:
            throw unsupportedValue(field: field, token: token)
        }
    }

    private func namedDay(_ rawValue: String) -> Date? {
        let date: Date?
        switch MailSearchLexer.fold(rawValue) {
        case "today":
            date = calendar.startOfDay(for: now)
        case "yesterday":
            date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            date = isoDay(rawValue)
        }
        guard let date, MailSearchQueryParser.isSupportedDate(date) else { return nil }
        return date
    }

    private func isoDay(_ rawValue: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var isoCalendar = Calendar(identifier: .gregorian)
        isoCalendar.locale = Locale(identifier: "en_US_POSIX")
        isoCalendar.timeZone = calendar.timeZone
        formatter.calendar = isoCalendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: rawValue), formatter.string(from: date) == rawValue else {
            return nil
        }
        let day = calendar.startOfDay(for: date)
        return MailSearchQueryParser.isSupportedDate(day) ? day : nil
    }

    private func relativeBoundary(_ rawValue: String) -> Date? {
        let value = MailSearchLexer.fold(rawValue)
        guard let suffix = value.last,
              ["d", "w", "m", "y"].contains(suffix),
              let amount = Int(value.dropLast()),
              amount > 0 else {
            return nil
        }
        let component: Calendar.Component
        switch suffix {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        default: component = .year
        }
        guard let boundary = calendar.date(byAdding: component, value: -amount, to: now),
              MailSearchQueryParser.isSupportedDate(boundary) else {
            return nil
        }
        return boundary
    }

    private mutating func recordTerm() throws {
        termCount += 1
        guard termCount <= MailSearchQueryParser.maximumTerms else {
            throw MailSearchError.invalidQuery(
                reason: "Too many terms; maximum is 64.",
                range: nil
            )
        }
    }

    private mutating func recordClause() throws {
        clauseCount += 1
        guard clauseCount <= MailSearchQueryParser.maximumClauses else {
            throw MailSearchError.invalidQuery(
                reason: "Too many clauses; maximum is 32.",
                range: nil
            )
        }
    }

    private var canStartExpression: Bool {
        switch current.kind {
        case .phrase, .leftParenthesis, .minus:
            return true
        case .word(let value):
            let folded = MailSearchLexer.fold(value)
            return folded != "and" && folded != "or"
        case .colon, .rightParenthesis, .end:
            return false
        }
    }

    private mutating func consumeKeyword(_ keyword: String) -> Bool {
        guard case .word(let value) = current.kind,
              MailSearchLexer.fold(value) == MailSearchLexer.fold(keyword) else {
            return false
        }
        advance()
        return true
    }

    private mutating func consumeMinus() -> Bool {
        guard current.kind == .minus else { return false }
        advance()
        return true
    }

    private var current: MailSearchLexer.Token {
        tokens[index]
    }

    private var peek: MailSearchLexer.Token {
        tokens[min(index + 1, tokens.count - 1)]
    }

    private mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    private func invalid(_ reason: String, at range: MailSearchTextRange) -> MailSearchError {
        .invalidQuery(reason: reason, range: range)
    }

    private func unsupportedValue(
        field: String,
        token: MailSearchLexer.Token
    ) -> MailSearchError {
        .unsupportedValue(field: field, range: token.range)
    }
}

extension MailSearchQueryExpression {
    package var isTextOnly: Bool {
        var pending = [self]
        var nodeCount = 0
        while let current = pending.popLast() {
            nodeCount += 1
            guard nodeCount <= MailSearchQueryParser.maximumExpressionNodeCount else {
                return false
            }
            switch current {
            case .matchAll:
                return false
            case .term, .phrase:
                continue
            case .all(let values), .any(let values):
                pending.append(contentsOf: values)
            case .not(let value):
                pending.append(value)
            case .field, .content, .state, .location, .date:
                return false
            }
        }
        return true
    }
}
