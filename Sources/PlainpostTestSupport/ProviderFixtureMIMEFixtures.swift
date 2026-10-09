import Foundation

// One bounded source generator drives the Go/Swift corpus limit dimensions.
// It is deliberately TestSupport-only: production only receives RFC 5322
// bytes, never fixture-specific dimension names.
enum ProviderFixtureMIMEFixtures {
    enum FixtureError: Error { case invalid }

    static func generated(
        _ generator: ProviderFixtureDocumentDecoder.GeneratorBoundary,
        amount: Int
    ) throws -> Data {
        guard amount == generator.accepted || amount == generator.rejected else {
            throw FixtureError.invalid
        }
        switch (generator.kind, generator.dimension) {
        case ("header_bytes", "body_bytes"):
            return Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + String(repeating: "b", count: amount)).utf8)
        case ("header_bytes", "header_bytes"):
            let prefix = "Subject: "
            guard amount >= prefix.utf8.count else { throw FixtureError.invalid }
            return Data((prefix + String(repeating: "h", count: amount - prefix.utf8.count) + "\r\n\r\nbody").utf8)
        case ("attachment_bytes", "attachment_bytes"):
            return Data(("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\nContent-Transfer-Encoding: base64\r\n\r\n" + base64AttachmentBody(decodedBytes: amount) + "\r\n").utf8)
        case ("aggregate_attachment_bytes", "aggregate_attachment_bytes"):
            let first = amount / 3
            let second = (amount - first) / 2
            let third = amount - first - second
            let parts = [first, second, third].map {
                "--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\nContent-Transfer-Encoding: binary\r\n\r\n" + String(repeating: "a", count: $0) + "\r\n"
            }.joined()
            return Data(("Content-Type: multipart/mixed; boundary=fixture\r\n\r\n" + parts + "--fixture--\r\n").utf8)
        case ("repeated_parts", "attachment_count"):
            let parts = (0 ..< amount).map {
                "--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\($0).bin\r\n\r\nx\r\n"
            }.joined()
            return Data(("Content-Type: multipart/mixed; boundary=fixture\r\n\r\n" + parts + "--fixture--\r\n").utf8)
        case ("repeated_parts", "attachment_metadata_bytes"):
            let filenames = try attachmentMetadataFilenames(totalBytes: amount)
            let parts = filenames.map {
                "--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\($0)\"\r\n\r\nx\r\n"
            }.joined()
            return Data(("Content-Type: multipart/mixed; boundary=fixture\r\n\r\n" + parts + "--fixture--\r\n").utf8)
        case ("repeated_parts", "part_count"):
            let parts = (0 ..< amount).map {
                "--fixture\r\nContent-Type: application/x-fixture-\($0)\r\n\r\nx\r\n"
            }.joined()
            return Data(("Content-Type: multipart/mixed; boundary=fixture\r\n\r\n" + parts + "--fixture--\r\n").utf8)
        case ("nested_multipart", "depth"):
            var message = ""
            for index in 0 ..< amount {
                message += "Content-Type: multipart/mixed; boundary=b\(index)\r\n\r\n--b\(index)\r\n"
            }
            message += "Content-Type: text/plain\r\n\r\nx\r\n"
            for index in (0 ..< amount).reversed() {
                message += "--b\(index)--\r\n"
            }
            return Data(message.utf8)
        default:
            throw FixtureError.invalid
        }
    }

    /// Produces 256 attachment filenames whose canonical descriptor fields
    /// (path, filename, MIME type, disposition, and empty Content-ID) total
    /// exactly `totalBytes`. The shared generator drives production metadata
    /// accounting; it is not an expected-result oracle.
    private static func attachmentMetadataFilenames(totalBytes: Int) throws -> [String] {
        let count = 256
        let fixedPerPart = "application/octet-stream".utf8.count + "attachment".utf8.count
        let fixed = (1 ... count).reduce(0) { partial, index in
            partial + String(index).utf8.count + fixedPerPart
        }
        let minimum = fixed + count
        let maximum = fixed + count * 255
        guard (minimum ... maximum).contains(totalBytes) else { throw FixtureError.invalid }

        var remaining = totalBytes - minimum
        return (0 ..< count).map { _ in
            let extra = min(254, remaining)
            remaining -= extra
            return String(repeating: "a", count: extra + 1)
        }
    }

    private static func base64AttachmentBody(decodedBytes: Int) -> String {
        var result = String(repeating: "YWFh", count: decodedBytes / 3)
        switch decodedBytes % 3 {
        case 1: result += "YQ=="
        case 2: result += "YWE="
        default: break
        }
        return result
    }

    static func headerBoundary(
        _ source: ProviderFixtureDocumentDecoder.HeaderBoundarySource,
        amount: Int
    ) throws -> Data {
        guard amount == source.accepted || amount == source.rejected else {
            throw FixtureError.invalid
        }
        let values: [String]
        switch source.dimension {
        case "count":
            values = (0 ..< amount).map { headerBoundaryValue(source, bytes: 16, index: $0) }
        case "aggregate_bytes":
            let count = 256
            let base = amount / count
            let remainder = amount % count
            values = (0 ..< count).map { index in
                headerBoundaryValue(source, bytes: base + (index < remainder ? 1 : 0), index: index)
            }
        default:
            throw FixtureError.invalid
        }
        let formatting: (name: String, separator: String)
        switch source.header {
        case "in_reply_to": formatting = ("In-Reply-To", "\r\n ")
        case "references": formatting = ("References", "\r\n ")
        case "to": formatting = ("To", ",\r\n ")
        case "cc": formatting = ("Cc", ",\r\n ")
        default: throw FixtureError.invalid
        }
        return Data((formatting.name + ": " + values.joined(separator: formatting.separator) + "\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbounded header").utf8)
    }

    static func headerBoundaryValue(
        _ source: ProviderFixtureDocumentDecoder.HeaderBoundarySource,
        bytes: Int,
        index: Int
    ) -> String {
        if source.kind == "message_ids" {
            let prefix = String(index)
            return "<\(prefix)\(String(repeating: "a", count: bytes - prefix.utf8.count - 4))@x>"
        }
        let prefix = "n\(index)"
        let mailbox = "a@x"
        return "\(prefix)\(String(repeating: "a", count: bytes - prefix.utf8.count - mailbox.utf8.count)) <\(mailbox)>"
    }
}
