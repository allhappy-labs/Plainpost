import Foundation

/// An image part a message's HTML can reference as `cid:`.
public struct InlineImagePart: Equatable, Sendable {
    /// The part's Content-ID without angle brackets, when the message stated one.
    public let contentID: String?
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(contentID: String?, filename: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Swaps `cid:` image sources for `data:` URLs built from the message's own
/// parts. The message view has no `cid:` loader, so without this an inline
/// signature logo or icon renders as an empty box.
public enum InlineImageResolver {
    /// Larger parts stay unresolved rather than bloating the page.
    public static let maximumImageBytes = 5 * 1_024 * 1_024
    public static let maximumTotalBytes = 15 * 1_024 * 1_024

    /// The Content-ID a `cid:` URL names: percent-decoded, brackets removed.
    public static func normalizedContentID(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.removingPercentEncoding ?? trimmed
    }

    public static func references(in html: String) -> Bool {
        html.range(of: "cid:", options: .caseInsensitive) != nil
    }

    public static func resolve(html: String, parts: [InlineImagePart]) -> String {
        let images = parts.filter {
            $0.mimeType.lowercased().hasPrefix("image/") && $0.data.count <= maximumImageBytes
        }
        guard !images.isEmpty, references(in: html),
              let expression = try? NSRegularExpression(
                pattern: #"(\bsrc\s*=\s*)(["']?)cid:([^"'\s>]+)\2"#,
                options: [.caseInsensitive]
              ) else { return html }

        var dataURLs: [Int: String] = [:]
        var totalBytes = 0
        func dataURL(for index: Int) -> String? {
            if let url = dataURLs[index] { return url }
            let image = images[index]
            guard totalBytes + image.data.count <= maximumTotalBytes else { return nil }
            totalBytes += image.data.count
            let url = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            dataURLs[index] = url
            return url
        }

        let source = html as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let reference = normalizedContentID(source.substring(with: match.range(at: 3)))
            guard let index = imageIndex(for: reference, in: images), let url = dataURL(for: index) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += source.substring(with: match.range(at: 1)) + "\"" + url + "\""
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return html }
        result += source.substring(from: cursor)
        return result
    }

    /// A stated Content-ID wins. Parts stored before Content-IDs were kept
    /// fall back to Outlook's convention, `cid:image001.png@01DD…` naming
    /// the file `image001.png`.
    private static func imageIndex(for reference: String, in images: [InlineImagePart]) -> Int? {
        if let index = images.firstIndex(where: {
            $0.contentID.map { normalizedContentID($0).caseInsensitiveCompare(reference) == .orderedSame } == true
        }) {
            return index
        }
        let localPart = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        guard !localPart.isEmpty else { return nil }
        let matches = images.indices.filter {
            images[$0].contentID == nil && images[$0].filename.caseInsensitiveCompare(localPart) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
