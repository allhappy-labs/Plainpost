import Foundation
import PlainpostCore

public enum MailTranslationContract {
    public static let version = "message-translation-v2"
}

public enum MailTranslationDocumentError: Error, Equatable {
    case invalidSegmentIdentity
}

enum MailTranslationToken: Equatable, Sendable {
    case immutable(String)
    case replaceable(source: String, segmentID: String)
}

public struct PreparedMailTranslation: Sendable {
    public let bodyKind: EmailBodyKind
    public let segments: [AITranslationSegment]
    let tokens: [MailTranslationToken]

    init(
        bodyKind: EmailBodyKind,
        segments: [AITranslationSegment],
        tokens: [MailTranslationToken]
    ) {
        self.bodyKind = bodyKind
        self.segments = segments
        self.tokens = tokens
    }

    public func batches(maxUTF8Bytes: Int) -> [[AITranslationSegment]] {
        var result: [[AITranslationSegment]] = []
        var current: [AITranslationSegment] = []
        var currentByteCount = 0

        for segment in segments {
            let byteCount = segment.text.utf8.count
            if !current.isEmpty, currentByteCount + byteCount > maxUTF8Bytes {
                result.append(current)
                current = []
                currentByteCount = 0
            }

            current.append(segment)
            currentByteCount += byteCount

            if maxUTF8Bytes <= 0 || byteCount > maxUTF8Bytes {
                result.append(current)
                current = []
                currentByteCount = 0
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    public func reconstruct(_ translations: [AITranslatedSegment]) throws -> RenderedEmailBody {
        let expected = Set(segments.map(\.id))
        let returned = Set(translations.map(\.id))
        guard expected == returned,
              expected.count == translations.count
        else {
            throw MailTranslationDocumentError.invalidSegmentIdentity
        }

        let translatedByID = Dictionary(
            uniqueKeysWithValues: translations.map { ($0.id, $0.translation) }
        )
        let body = tokens.map { token in
            switch token {
            case let .immutable(value):
                return value
            case let .replaceable(_, segmentID):
                let translation = translatedByID[segmentID, default: ""]
                return bodyKind == .html
                    ? translation.escapingTranslationMarkup()
                    : translation
            }
        }.joined()

        return MailTranslationDocument.renderTranslatedBody(body, kind: bodyKind)
    }
}

public enum MailTranslationDocument {
    public static func prepare(_ body: RenderedEmailBody) throws -> PreparedMailTranslation {
        switch body.kind {
        case .plainText:
            return Tokenizer(bodyKind: .plainText).prepare(body.safeText)
        case .html:
            return Tokenizer(bodyKind: .html).prepare(body.safeHTML ?? "")
        }
    }

    static func renderTranslatedBody(
        _ translatedBody: String,
        kind: EmailBodyKind
    ) -> RenderedEmailBody {
        switch kind {
        case .plainText:
            return RenderedEmailBody(
                kind: .plainText,
                safeText: translatedBody,
                blockedRemoteImageURLs: []
            )
        case .html:
            return RenderedEmailBody(
                kind: .html,
                safeText: translatedBody.translationSafeTextFromHTML(),
                safeHTML: translatedBody,
                blockedRemoteImageURLs: EmailBodyRenderer.remoteImageURLs(
                    inHTML: translatedBody
                )
            )
        }
    }
}

private struct Tokenizer {
    private static let suppressedTags: Set<String> = [
        "audio",
        "canvas",
        "code",
        "embed",
        "head",
        "iframe",
        "math",
        "metadata",
        "noembed",
        "noscript",
        "object",
        "picture",
        "script",
        "style",
        "svg",
        "template",
        "title",
        "video",
    ]
    private static let voidTags: Set<String> = [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    ]
    private static let protectedTextRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(?<![a-z0-9+.\-])[a-z][a-z0-9+.\-]*:[^\s<>"']*"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{M}\p{N}@._\-])(?:www\.)?(?:[\p{L}\p{M}\p{N}](?:[\p{L}\p{M}\p{N}\-]*[\p{L}\p{M}\p{N}])?\.)+[\p{L}\p{M}\p{N}](?:[\p{L}\p{M}\p{N}\-]*[\p{L}\p{M}\p{N}])?(?::[0-9]+)?(?:[/?#][^\s<>"']*)?"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)(?:"(?:\\[^\r\n]|[^"\\\r\n])*"|[^\s<>"(),:;@\[\]]+)@(?:\[[^\]\r\n]+\]|[^\s<>"(),:;@\[\]]+)"#
        ),
    ]

    let bodyKind: EmailBodyKind

    func prepare(_ source: String) -> PreparedMailTranslation {
        if bodyKind == .plainText {
            var tokens: [MailTranslationToken] = []
            var segments: [AITranslationSegment] = []
            appendText(source, tokens: &tokens, segments: &segments)
            return PreparedMailTranslation(
                bodyKind: bodyKind,
                segments: segments,
                tokens: tokens
            )
        }

        let scalars = Array(source.unicodeScalars)
        var tokens: [MailTranslationToken] = []
        var segments: [AITranslationSegment] = []
        var suppressedTagStack: [String] = []
        var cursor = 0

        while cursor < scalars.count {
            if scalars[cursor] == "<" {
                let end = markupEnd(in: scalars, startingAt: cursor)
                let markup = string(from: scalars[cursor..<end])
                appendImmutable(markup, to: &tokens)
                updateSuppressionStack(&suppressedTagStack, with: markup)
                cursor = end
                continue
            }

            let start = cursor
            while cursor < scalars.count, scalars[cursor] != "<" {
                cursor += 1
            }
            let text = string(from: scalars[start..<cursor])
            if suppressedTagStack.isEmpty {
                appendText(text, tokens: &tokens, segments: &segments)
            } else {
                appendImmutable(text, to: &tokens)
            }
        }

        return PreparedMailTranslation(
            bodyKind: bodyKind,
            segments: segments,
            tokens: tokens
        )
    }

    private func markupEnd(
        in scalars: [Unicode.Scalar],
        startingAt start: Int
    ) -> Int {
        if hasPrefix("<!--", in: scalars, startingAt: start) {
            var cursor = start + 4
            while cursor < scalars.count {
                if hasPrefix("-->", in: scalars, startingAt: cursor) {
                    return cursor + 3
                }
                cursor += 1
            }
            return scalars.count
        }

        var quote: Unicode.Scalar?
        var cursor = start + 1
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return cursor + 1
            }
            cursor += 1
        }
        return scalars.count
    }

    private func updateSuppressionStack(_ stack: inout [String], with markup: String) {
        guard let tag = tagDescription(markup),
              Self.suppressedTags.contains(tag.name)
        else {
            return
        }

        if tag.isClosing {
            if stack.last == tag.name {
                stack.removeLast()
            }
        } else if !tag.isSelfClosing, !Self.voidTags.contains(tag.name) {
            stack.append(tag.name)
        }
    }

    private func tagDescription(_ markup: String) -> TagDescription? {
        let scalars = Array(markup.unicodeScalars)
        guard scalars.first == "<", scalars.count > 2 else {
            return nil
        }

        var cursor = 1
        while cursor < scalars.count, scalars[cursor].properties.isWhitespace {
            cursor += 1
        }
        guard cursor < scalars.count,
              scalars[cursor] != "!",
              scalars[cursor] != "?"
        else {
            return nil
        }

        let isClosing = scalars[cursor] == "/"
        if isClosing {
            cursor += 1
            while cursor < scalars.count, scalars[cursor].properties.isWhitespace {
                cursor += 1
            }
        }

        let nameStart = cursor
        while cursor < scalars.count, isTagNameScalar(scalars[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart else {
            return nil
        }

        var tail = scalars.count - 1
        if tail >= 0, scalars[tail] == ">" {
            tail -= 1
        }
        while tail >= 0, scalars[tail].properties.isWhitespace {
            tail -= 1
        }

        return TagDescription(
            name: string(from: scalars[nameStart..<cursor]).lowercased(),
            isClosing: isClosing,
            isSelfClosing: tail >= 0 && scalars[tail] == "/"
        )
    }

    private func appendText(
        _ text: String,
        tokens: inout [MailTranslationToken],
        segments: inout [AITranslationSegment]
    ) {
        guard !text.isEmpty else {
            return
        }

        let protectedRanges = protectedRanges(in: text)
        var cursor = text.startIndex
        for range in protectedRanges {
            appendReplaceable(
                String(text[cursor..<range.lowerBound]),
                tokens: &tokens,
                segments: &segments
            )
            appendImmutable(String(text[range]), to: &tokens)
            cursor = range.upperBound
        }
        appendReplaceable(
            String(text[cursor...]),
            tokens: &tokens,
            segments: &segments
        )
    }

    private func appendReplaceable(
        _ text: String,
        tokens: inout [MailTranslationToken],
        segments: inout [AITranslationSegment]
    ) {
        guard !text.isEmpty else {
            return
        }
        guard !text.unicodeScalars.allSatisfy(\.properties.isWhitespace) else {
            appendImmutable(text, to: &tokens)
            return
        }

        let id = "segment-\(segments.count)"
        segments.append(AITranslationSegment(id: id, text: text))
        tokens.append(.replaceable(source: text, segmentID: id))
    }

    private func protectedRanges(in text: String) -> [Range<String.Index>] {
        let decodedShadow = EntityDecodedShadow(source: text)
        let fullRange = NSRange(
            decodedShadow.value.startIndex..<decodedShadow.value.endIndex,
            in: decodedShadow.value
        )
        var ranges = Self.protectedTextRegexes
            .flatMap { regex in
                regex.matches(in: decodedShadow.value, range: fullRange).compactMap {
                    match -> Range<String.Index>? in
                    guard let shadowRange = Range(match.range, in: decodedShadow.value) else {
                        return nil
                    }
                    return decodedShadow.sourceRange(
                        for: NSRange(shadowRange, in: decodedShadow.value)
                    )
                }
            }
        if bodyKind == .plainText {
            ranges.append(contentsOf: plainTextCodeRanges(in: text))
        }
        ranges.sort { lhs, rhs in
                if lhs.lowerBound == rhs.lowerBound {
                    return lhs.upperBound > rhs.upperBound
                }
                return lhs.lowerBound < rhs.lowerBound
            }

        var merged: [Range<String.Index>] = []
        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func plainTextCodeRanges(in text: String) -> [Range<String.Index>] {
        fencedCodeRanges(in: text)
            + inlineCodeRanges(in: text)
            + indentedCodeRanges(in: text)
    }

    private func fencedCodeRanges(in text: String) -> [Range<String.Index>] {
        let lines = lineRanges(in: text)
        var ranges: [Range<String.Index>] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = text[lines[lineIndex]]
            guard let opener = fenceDescription(in: line, minimumLength: 3) else {
                lineIndex += 1
                continue
            }

            let fenceStart = lines[lineIndex].lowerBound
            var closingLineIndex = lineIndex + 1
            while closingLineIndex < lines.count {
                let candidate = text[lines[closingLineIndex]]
                if let closer = fenceDescription(
                    in: candidate,
                    minimumLength: opener.length
                ), closer.marker == opener.marker,
                   closer.length >= opener.length,
                   closer.hasOnlyWhitespaceAfterMarker {
                    break
                }
                closingLineIndex += 1
            }

            let fenceEnd = closingLineIndex < lines.count
                ? lines[closingLineIndex].upperBound
                : text.endIndex
            ranges.append(fenceStart..<fenceEnd)
            lineIndex = closingLineIndex < lines.count
                ? closingLineIndex + 1
                : lines.count
        }
        return ranges
    }

    private func inlineCodeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == "`" else {
                cursor = text.index(after: cursor)
                continue
            }
            let opener = cursor
            var openerEnd = cursor
            while openerEnd < text.endIndex, text[openerEnd] == "`" {
                openerEnd = text.index(after: openerEnd)
            }
            let delimiterLength = text.distance(from: opener, to: openerEnd)

            var search = openerEnd
            var closingEnd: String.Index?
            while search < text.endIndex {
                guard text[search] == "`" else {
                    search = text.index(after: search)
                    continue
                }
                var candidateEnd = search
                while candidateEnd < text.endIndex, text[candidateEnd] == "`" {
                    candidateEnd = text.index(after: candidateEnd)
                }
                if text.distance(from: search, to: candidateEnd) == delimiterLength {
                    closingEnd = candidateEnd
                    break
                }
                search = candidateEnd
            }

            let end = closingEnd ?? text.endIndex
            ranges.append(opener..<end)
            cursor = end
        }
        return ranges
    }

    private func indentedCodeRanges(in text: String) -> [Range<String.Index>] {
        lineRanges(in: text).filter { range in
            let line = text[range]
            return line.hasPrefix("\t") || line.hasPrefix("    ")
        }
    }

    private func lineRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(of: "\n")
            let end = newline.map { text.index(after: $0) } ?? text.endIndex
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private func fenceDescription(
        in line: Substring,
        minimumLength: Int
    ) -> FenceDescription? {
        var cursor = line.startIndex
        var leadingSpaces = 0
        while cursor < line.endIndex, line[cursor] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            cursor = line.index(after: cursor)
        }
        guard leadingSpaces <= 3,
              cursor < line.endIndex,
              line[cursor] == "`" || line[cursor] == "~"
        else {
            return nil
        }

        let marker = line[cursor]
        let markerStart = cursor
        while cursor < line.endIndex, line[cursor] == marker {
            cursor = line.index(after: cursor)
        }
        let length = line.distance(from: markerStart, to: cursor)
        guard length >= minimumLength else {
            return nil
        }
        let remainder = line[cursor...]
        return FenceDescription(
            marker: marker,
            length: length,
            hasOnlyWhitespaceAfterMarker: remainder.allSatisfy {
                $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
            }
        )
    }

    private func appendImmutable(_ value: String, to tokens: inout [MailTranslationToken]) {
        guard !value.isEmpty else {
            return
        }
        if case let .immutable(previous)? = tokens.last {
            tokens[tokens.count - 1] = .immutable(previous + value)
        } else {
            tokens.append(.immutable(value))
        }
    }

    private func hasPrefix(
        _ prefix: String,
        in scalars: [Unicode.Scalar],
        startingAt start: Int
    ) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        guard start + prefixScalars.count <= scalars.count else {
            return false
        }
        return scalars[start..<(start + prefixScalars.count)].elementsEqual(prefixScalars)
    }

    private func isTagNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
            || scalar.properties.numericType != nil
            || scalar == ":"
            || scalar == "-"
            || scalar == "_"
    }

    private func string<C: Collection>(from scalars: C) -> String where C.Element == Unicode.Scalar {
        String(String.UnicodeScalarView(scalars))
    }

    private struct TagDescription {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private struct FenceDescription {
        let marker: Character
        let length: Int
        let hasOnlyWhitespaceAfterMarker: Bool
    }

    private struct EntityDecodedShadow {
        let value: String
        private let mappings: [Mapping]

        init(source: String) {
            var value = ""
            var mappings: [Mapping] = []
            var cursor = source.startIndex
            var shadowUTF16Offset = 0

            while cursor < source.endIndex {
                let sourceEnd: String.Index
                let decoded: String
                if let entity = Self.decodedEntity(in: source, startingAt: cursor) {
                    sourceEnd = entity.sourceEnd
                    decoded = entity.value
                } else {
                    sourceEnd = source.index(after: cursor)
                    decoded = String(source[cursor..<sourceEnd])
                }

                value.append(decoded)
                mappings.append(
                    Mapping(
                        shadowUTF16Range: shadowUTF16Offset..<(shadowUTF16Offset + decoded.utf16.count),
                        sourceRange: cursor..<sourceEnd
                    )
                )
                shadowUTF16Offset += decoded.utf16.count
                cursor = sourceEnd
            }

            self.value = value
            self.mappings = mappings
        }

        func sourceRange(for shadowUTF16Range: NSRange) -> Range<String.Index>? {
            let requestedRange = shadowUTF16Range.location..<NSMaxRange(shadowUTF16Range)
            let overlapping = mappings.filter {
                $0.shadowUTF16Range.lowerBound < requestedRange.upperBound
                    && requestedRange.lowerBound < $0.shadowUTF16Range.upperBound
            }
            guard let first = overlapping.first, let last = overlapping.last else {
                return nil
            }
            return first.sourceRange.lowerBound..<last.sourceRange.upperBound
        }

        private static func decodedEntity(
            in source: String,
            startingAt start: String.Index
        ) -> (sourceEnd: String.Index, value: String)? {
            guard source[start] == "&" else {
                return nil
            }

            var cursor = source.index(after: start)
            guard cursor < source.endIndex else {
                return nil
            }
            if source[cursor] == "#" {
                cursor = source.index(after: cursor)
                var radix = 10
                if cursor < source.endIndex,
                   source[cursor] == "x" || source[cursor] == "X" {
                    radix = 16
                    cursor = source.index(after: cursor)
                }
                let digitsStart = cursor
                while cursor < source.endIndex,
                      isDigit(source[cursor], radix: radix),
                      source.distance(from: digitsStart, to: cursor) < 8 {
                    cursor = source.index(after: cursor)
                }
                guard cursor > digitsStart,
                      let value = unicodeScalar(
                          String(source[digitsStart..<cursor]),
                          radix: radix
                      )
                else {
                    return nil
                }
                if cursor < source.endIndex, source[cursor] == ";" {
                    cursor = source.index(after: cursor)
                }
                return (cursor, value)
            }

            guard let semicolon = source[cursor...].firstIndex(of: ";"),
                  source.distance(from: start, to: semicolon) <= 32,
                  let value = namedEntities[String(source[cursor..<semicolon])]
            else {
                return nil
            }
            return (source.index(after: semicolon), value)
        }

        private static func isDigit(_ character: Character, radix: Int) -> Bool {
            switch character {
            case "0"..."9":
                true
            case "a"..."f", "A"..."F":
                radix == 16
            default:
                false
            }
        }

        private static func unicodeScalar(_ digits: String, radix: Int) -> String? {
            guard let value = UInt32(digits, radix: radix),
                  let scalar = Unicode.Scalar(value)
            else {
                return nil
            }
            return String(scalar)
        }

        private static let namedEntities: [String: String] = [
            "amp": "&",
            "apos": "'",
            "colon": ":",
            "commat": "@",
            "equals": "=",
            "gt": ">",
            "lt": "<",
            "nbsp": " ",
            "num": "#",
            "period": ".",
            "quest": "?",
            "quot": "\"",
            "sol": "/",
        ]

        private struct Mapping {
            let shadowUTF16Range: Range<Int>
            let sourceRange: Range<String.Index>
        }
    }
}

private extension String {
    func escapingTranslationMarkup() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func translationSafeTextFromHTML() -> String {
        replacingTranslationMatches(pattern: #"(?is)<!--.*?-->"#, with: "")
            .replacingTranslationMatches(
                pattern: #"(?is)<style\b[^>]*>.*?</style>"#,
                with: ""
            )
            .replacingTranslationMatches(pattern: #"(?is)<img\b[^>]*>"#, with: "")
            .replacingTranslationMatches(pattern: #"(?i)</p\s*>"#, with: "\n\n")
            .replacingTranslationMatches(pattern: #"(?i)</div\s*>"#, with: "\n")
            .replacingTranslationMatches(pattern: #"(?i)</li\s*>"#, with: "\n")
            .replacingTranslationMatches(pattern: #"(?i)</tr\s*>"#, with: "\n")
            .replacingTranslationMatches(pattern: #"(?i)<br\s*/?>"#, with: "\n")
            .replacingTranslationMatches(pattern: #"(?is)<[^>]+>"#, with: "")
            .decodingTranslationHTMLEntities()
            .normalizingTranslationDisplayWhitespace()
    }

    func replacingTranslationMatches(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(
            in: self,
            range: range,
            withTemplate: replacement
        )
    }

    func decodingTranslationHTMLEntities() -> String {
        replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    func normalizingTranslationDisplayWhitespace() -> String {
        let lines = replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }

        var normalized: [String] = []
        var previousWasBlank = true
        for line in lines {
            if line.isEmpty {
                if !previousWasBlank {
                    normalized.append("")
                }
                previousWasBlank = true
            } else {
                normalized.append(line)
                previousWasBlank = false
            }
        }
        while normalized.last?.isEmpty == true {
            normalized.removeLast()
        }
        return normalized.joined(separator: "\n")
    }
}
