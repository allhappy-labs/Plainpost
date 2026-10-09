import Foundation

public enum MailSearchDocumentClassifier {
    public static let ambiguousMIMETypes: Set<String> = [
        "application/octet-stream",
        "binary/octet-stream",
    ]

    public static let filenameExtensions: Set<String> = [
        "csv", "doc", "docx", "key", "md", "numbers", "odp", "ods", "odt",
        "pages", "pdf", "ppt", "pptx", "rtf", "tsv", "txt", "xls", "xlsx",
    ]

    public static let mimeTypes: Set<String> = [
        "application/msword",
        "application/pdf",
        "application/rtf",
        "application/vnd.apple.keynote",
        "application/vnd.apple.numbers",
        "application/vnd.apple.pages",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/vnd.oasis.opendocument.presentation",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/csv",
        "text/markdown",
        "text/plain",
        "text/rtf",
        "text/tab-separated-values",
    ]

    public static func isDocument(filename: String, mimeType: String?) -> Bool {
        if let canonical = canonicalMIMEType(mimeType),
           !ambiguousMIMETypes.contains(canonical) {
            return mimeTypes.contains(canonical)
        }
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return filenameExtensions.contains(filenameExtension)
    }

    public static func canonicalMIMEType(_ mimeType: String?) -> String? {
        guard let trimmed = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let canonical = trimmed
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return canonical?.isEmpty == false ? canonical : nil
    }
}
