import CryptoKit
import XCTest
@testable import PlainpostCore
@testable import PlainpostTestSupport

final class MIMEMessageAttachmentTests: XCTestCase {
    func testProviderProjectionIsTypedAndContentFree() throws {
        let projection = try MIMEMessageDecoder.providerProjection(
            from: Data("Subject: fixture\r\nContent-Type: text/plain\r\n\r\nbody".utf8)
        )
        XCTAssertEqual(projection.subject, "fixture")
        XCTAssertEqual(projection.textBody, .complete("body"))
        XCTAssertTrue(projection.parts.isEmpty)
    }

    func testProviderProjectionMapsNestedAlternativeTextAndSanitizedHTMLAlongsideAttachment() throws {
        let source = [
            "Message-ID: <nested-alternative@example.invalid>",
            "Subject: Nested alternative",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=outer",
            "",
            "--outer",
            "Content-Type: multipart/alternative; boundary=alternative",
            "",
            "--alternative",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            "Unicode acceptance body",
            "--alternative",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            "<p>Unicode <strong>acceptance</strong> body</p>",
            "--alternative--",
            "--outer",
            "Content-Type: application/octet-stream; name=fixture.bin",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=fixture.bin",
            "",
            "ZmFrZQ==",
            "--outer--",
            ""
        ].joined(separator: "\r\n")

        let projection = try MIMEMessageDecoder.providerProjection(from: Data(source.utf8))

        XCTAssertEqual(projection.textBody, .complete("Unicode acceptance body"))
        XCTAssertEqual(projection.htmlBody, .complete("<p>Unicode <strong>acceptance</strong> body</p>"))
        XCTAssertEqual(projection.parts.count, 1)
        XCTAssertEqual(projection.parts.first?.mediaType, "application/octet-stream")
    }

    func testProductionAttachmentCountAndMetadataLimitsExecuteBothBoundaries() throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixture = try XCTUnwrap(
            try ProviderFixtureDocumentDecoder.mimeFixtures(document).first {
                $0.id == "attachments-256-and-metadata-64kib-boundaries"
            }
        )
        let compoundGenerator = try XCTUnwrap(fixture.generator)
        XCTAssertEqual(compoundGenerator.kind, "repeated_parts")
        XCTAssertEqual(compoundGenerator.dimension, "attachment_boundaries")
        XCTAssertEqual(compoundGenerator.boundaryCases.count, 2)
        let countGenerator = try XCTUnwrap(compoundGenerator.boundaryCases.first {
            $0.dimension == "attachment_count"
        })
        let metadataGenerator = try XCTUnwrap(compoundGenerator.boundaryCases.first {
            $0.dimension == "attachment_metadata_bytes"
        })

        let accepted = try ProviderFixtureMIMEFixtures.generated(
            countGenerator,
            amount: countGenerator.accepted
        )
        let projection = try MIMEMessageDecoder.providerProjection(from: accepted)
        XCTAssertEqual(projection.parts.count, 256)
        let rejectedCount = try ProviderFixtureMIMEFixtures.generated(
            countGenerator,
            amount: countGenerator.rejected
        )
        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: rejectedCount))

        let acceptedMetadata = try ProviderFixtureMIMEFixtures.generated(
            metadataGenerator,
            amount: metadataGenerator.accepted
        )
        let metadataProjection = try MIMEMessageDecoder.providerProjection(from: acceptedMetadata)
        var metadataBytes = 0
        for part in metadataProjection.parts {
            metadataBytes += part.path.utf8.count
            metadataBytes += part.filename.utf8.count
            metadataBytes += part.mediaType.utf8.count
            metadataBytes += part.disposition.utf8.count
            metadataBytes += part.contentID.utf8.count
        }
        XCTAssertEqual(
            metadataBytes,
            metadataGenerator.accepted
        )

        let rejected = try ProviderFixtureMIMEFixtures.generated(
            metadataGenerator,
            amount: metadataGenerator.rejected
        )
        XCTAssertThrowsError(try MIMEMessageDecoder.providerProjection(from: rejected))
    }

    func testSharedCorpusAndEveryProductionLimitBoundary() throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
        XCTAssertEqual(fixtures.count, 20)

        // These markers make every descriptive corpus case prove the named
        // RFC 5322/MIME behavior is present in the production input, rather
        // than merely reusing a short text/plain placeholder under a label.
        let semantics: [String: [String]] = [
            "multipart-alternative-prefers-plain": ["multipart/alternative", "text/html"],
            "encoded-unicode-subject-and-address": ["=?UTF-8?", "From:"],
            "windows-charsets-and-flowed-text": ["windows-1252", "format=flowed"],
            "nested-signed-related-and-inline-rfc822": ["multipart/signed", "multipart/related", "Content-ID:"],
            "attached-rfc822-is-not-display-body": ["message/rfc822", "Content-Disposition: attachment"],
            "rfc2231-unicode-filename-sanitized-nfc": ["filename*0*=", "filename*1*=", "%CC%81"],
            "duplicate-filenames-preserve-part-paths": ["filename=duplicate", "multipart/mixed"],
            "base64-and-quoted-printable-attachments": ["base64", "quoted-printable"],
            "message-id-references-normalized-and-bounded": ["Message-ID:", "References:"],
            "missing-content-type-defaults-text-plain-us-ascii": ["Subject:"],
            "malformed-base64-rejects-part-bytes": ["Content-Transfer-Encoding: base64", "Content-Disposition: attachment"],
            "unsupported-transfer-encoding-rejects-part-bytes": ["Content-Transfer-Encoding: x-", "Content-Disposition: attachment"],
            "nul-rejected-other-controls-normalized": ["Subject:", "\u{0000}"],
        ]
        for fixture in fixtures where fixture.input != nil {
            let input = try XCTUnwrap(fixture.input, fixture.id)
            let source = try XCTUnwrap(String(data: input, encoding: .isoLatin1), fixture.id)
            for marker in semantics[fixture.id] ?? [] {
                XCTAssertTrue(source.contains(marker), "\(fixture.id) misses \(marker)")
            }
            let expectation = try XCTUnwrap(fixture.expectation, fixture.id)
            XCTAssertEqual(
                try ProviderFixtureDocumentDecoder.mimeProjection(from: input),
                expectation.projection,
                fixture.id
            )
            if expectation.attachments.contains(where: { $0.bytesError == "protocol" }) {
                XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: input), fixture.id) { error in
                    XCTAssertEqual(error as? MIMEAttachmentDecodingError, .malformedMessage, fixture.id)
                }
            } else {
                XCTAssertEqual(
                    try MIMEMessageDecoder.decodedAttachments(from: input),
                    try ProviderFixtureDocumentDecoder.hydratedAttachmentPayloads(for: expectation),
                    fixture.id
                )
            }
        }
        for fixture in fixtures {
            for generator in fixture.generator?.boundaryCases ?? [] {
                try Self.assertGenerator(generator, fixtureID: fixture.id)
            }
        }
    }

    func testFixtureProjectionRetainsCIDDescriptorAndDefersMalformedPartBytes() throws {
        let message = Data("""
            Content-Type: multipart/related; boundary=parts\r
            \r
            --parts\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <img src=\"cid:logo@example.invalid\">\r
            --parts\r
            Content-Type: image/png\r
            Content-Disposition: inline\r
            Content-ID: <logo@example.invalid>\r
            Content-Transfer-Encoding: base64\r
            \r
            %%%\r
            --parts--\r
            """.utf8)

        let projection = try ProviderFixtureDocumentDecoder.mimeProjection(from: message)
        XCTAssertEqual(projection.parts.count, 1)
        let part = try XCTUnwrap(projection.parts.first)
        XCTAssertEqual(part.path, "2")
        XCTAssertEqual(part.filename, "Attachment")
        XCTAssertEqual(part.mediaType, "image/png")
        XCTAssertEqual(part.disposition, "inline")
        XCTAssertEqual(part.contentID, "<logo@example.invalid>")
        XCTAssertEqual(part.declaredSize, 0)
        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: message))
    }

    func testFixtureProjectionCanonicalizesAddressesIDsAndControls() throws {
        let encodedJose = "=?UTF-8?B?Sm9zw6k=?="
        let source = [
            "From: \"Doe, Jane\" <JANE@example.invalid>, \(encodedJose) <JOSE@example.invalid>\r\n",
            "Subject: =?UTF-8?B?UsOpc3Vtw6k=?=\u{0001}title\r\n",
            "Message-ID: <root@example.invalid>\r\n",
            "In-Reply-To: <one@example.invalid> <two@example.invalid>\r\n",
            "References: <one@example.invalid>\r\n <two@example.invalid>\r\n",
            "Content-Type: text/plain; charset=utf-8\r\n\r\n",
            "visible\u{0000}hidden"
        ].joined()
        let message = Data(source.utf8)

        let projection = try ProviderFixtureDocumentDecoder.mimeProjection(from: message)
        XCTAssertEqual(projection.subject, "Résumé title")
        XCTAssertEqual(projection.from, [
            .init(displayName: "Doe, Jane", mailbox: "JANE@example.invalid"),
            .init(displayName: "José", mailbox: "JOSE@example.invalid"),
        ])
        XCTAssertEqual(projection.rfcMessageID, "<root@example.invalid>")
        XCTAssertEqual(projection.inReplyTo, ["<one@example.invalid>", "<two@example.invalid>"])
        XCTAssertEqual(projection.references, ["<one@example.invalid>", "<two@example.invalid>"])
        XCTAssertEqual(projection.textBody, .malformed)
    }

    func testFixtureProjectionDecodesWindows1252FlowedText() throws {
        let headers = Data("Content-Type: text/plain; charset=windows-1252; format=flowed; delsp=yes\r\n\r\n".utf8)
        let body = Data([80, 114, 105, 99, 101, 58, 32, 147, 113, 117, 111, 116, 101, 100, 148, 32, 13, 10, 99, 111, 110, 116, 105, 110, 117, 101, 115])
        let projection = try ProviderFixtureDocumentDecoder.mimeProjection(from: headers + body)
        XCTAssertEqual(projection.textBody, .complete("Price: “quoted”continues"))
    }

    func testDecodesNestedBase64QuotedPrintableAndInlineNamedAttachments() throws {
        let message = Data("""
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="Outer"\r
            \r
            --Outer\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Message body\r
            --Outer\r
            Content-Type: Text/Plain; charset=utf-8; name*=UTF-8''r%C3%A9sum%C3%A9%2F2026.txt\r
            Content-Disposition: inline\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            first=0Asecond\r
            --Outer\r
            Content-Type: multipart/related; boundary="Related"\r
            \r
            --Related\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <p>Related body</p>\r
            --Related\r
            Content-Type: IMAGE/PNG\r
            Content-Disposition: attachment; filename="chart.png"\r
            Content-Transfer-Encoding: base64\r
            \r
            AAECA/8=\r
            --Related--\r
            --Outer--\r
            """.utf8)

        let attachments = try MIMEMessageDecoder.decodedAttachments(from: message)

        XCTAssertEqual(attachments.map(\.partPath), ["2", "3.2"])
        XCTAssertEqual(attachments.map(\.filename), ["résumé_2026.txt", "chart.png"])
        XCTAssertEqual(attachments.map(\.mimeType), ["text/plain", "image/png"])
        XCTAssertEqual(attachments.map(\.data), [
            Data("first\nsecond".utf8),
            Data([0, 1, 2, 3, 255]),
        ])
        XCTAssertEqual(attachments.map(\.byteCount), [12, 5])
        XCTAssertEqual(
            attachments.map(\.sha256),
            attachments.map { Self.sha256($0.data) }
        )
        XCTAssertTrue(attachments.allSatisfy {
            $0.sha256.count == 64 &&
                $0.sha256.allSatisfy { $0.isNumber || ("a" ... "f").contains(String($0)) }
        })
    }

    func testAttachmentDecodeRejectsDecodedSizeAndPartCountLimits() {
        let oversized = Data("""
            Content-Type: application/octet-stream; name="large.bin"\r
            Content-Disposition: attachment; filename="large.bin"\r
            Content-Transfer-Encoding: base64\r
            \r
            AAECAwQ=\r
            """.utf8)
        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(
            from: oversized,
            limits: MIMEAttachmentDecodingLimits(
                maximumPartCount: 8,
                maximumAttachmentCount: 4,
                maximumDecodedBytesPerAttachment: 4,
                maximumAggregateDecodedBytes: 8
            )
        )) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .decodedSizeLimitExceeded)
        }

        let tooManyParts = Data("""
            Content-Type: multipart/mixed; boundary="Many"\r
            \r
            --Many\r
            Content-Type: text/plain\r
            \r
            body\r
            --Many\r
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="one.bin"\r
            \r
            one\r
            --Many\r
            Content-Type: text/plain\r
            \r
            another\r
            --Many--\r
            """.utf8)
        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(
            from: tooManyParts,
            limits: MIMEAttachmentDecodingLimits(
                maximumPartCount: 2,
                maximumAttachmentCount: 4,
                maximumDecodedBytesPerAttachment: 32,
                maximumAggregateDecodedBytes: 64
            )
        )) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .partCountLimitExceeded)
        }
    }

    func testAttachmentDecodeRejectsAggregateAndAttachmentCountLimits() {
        let message = Data("""
            Content-Type: multipart/mixed; boundary="Limits"\r
            \r
            --Limits\r
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="one.bin"\r
            \r
            one\r
            --Limits\r
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="two.bin"\r
            \r
            two\r
            --Limits--\r
            """.utf8)

        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(
            from: message,
            limits: MIMEAttachmentDecodingLimits(
                maximumPartCount: 8,
                maximumAttachmentCount: 1,
                maximumDecodedBytesPerAttachment: 8,
                maximumAggregateDecodedBytes: 16
            )
        )) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .attachmentCountLimitExceeded)
        }
        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(
            from: message,
            limits: MIMEAttachmentDecodingLimits(
                maximumPartCount: 8,
                maximumAttachmentCount: 2,
                maximumDecodedBytesPerAttachment: 8,
                maximumAggregateDecodedBytes: 5
            )
        )) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .decodedSizeLimitExceeded)
        }
    }

    func testProductionAttachmentCountLimitIs256() {
        let message = Self.repeatedAttachmentMessage(count: 257)

        XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: message)) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .attachmentCountLimitExceeded)
        }
    }

    func testProductionHeaderLimitRejectsPlusOne() {
        let accepted = Self.headerMessage(bytes: 2 * 1_024 * 1_024)
        let rejected = Self.headerMessage(bytes: 2 * 1_024 * 1_024 + 1)

        XCTAssertEqual(MIMEMessageDecoder.exactPlainText(from: accepted), "body")
        XCTAssertNil(MIMEMessageDecoder.exactPlainText(from: rejected))
    }

    func testAttachmentDecodeRejectsMalformedBase64InsteadOfPersistingEncodedBytes() {
        let malformed = Data("""
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="broken.bin"\r
            Content-Transfer-Encoding: base64\r
            \r
            definitely-not-base64***\r
            """.utf8)

        XCTAssertThrowsError(
            try MIMEMessageDecoder.decodedAttachments(from: malformed)
        )
    }

    func testAttachmentDecodeRejectsUnsupportedTransferEncoding() {
        let unsupported = Data("""
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="unknown.bin"\r
            Content-Transfer-Encoding: x-custom-compression\r
            \r
            opaque bytes\r
            """.utf8)

        XCTAssertThrowsError(
            try MIMEMessageDecoder.decodedAttachments(from: unsupported)
        )
    }

    func testAttachmentDecodeRejectsWholeTreeWhenNestingDepthIsExceeded() {
        var entity = """
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="deep.bin"\r
            \r
            payload
            """
        for depth in 0 ... 64 {
            let boundary = "Depth\(depth)"
            entity = """
                Content-Type: multipart/mixed; boundary="\(boundary)"\r
                \r
                --\(boundary)\r
                \(entity)\r
                --\(boundary)--\r
                """
        }

        XCTAssertThrowsError(
            try MIMEMessageDecoder.decodedAttachments(from: Data(entity.utf8))
        ) { error in
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .nestingDepthLimitExceeded)
        }
    }

    private static func assertGenerator(
        _ generator: ProviderFixtureDocumentDecoder.GeneratorBoundary,
        fixtureID: String
    ) throws {
        let acceptedData = try ProviderFixtureMIMEFixtures.generated(
            generator,
            amount: generator.accepted
        )
        let acceptedProjection = try ProviderFixtureDocumentDecoder.mimeProjection(from: acceptedData)
        if generator.dimension == "body_bytes" {
            XCTAssertEqual(
                acceptedProjection.textBody,
                .complete(String(repeating: "b", count: generator.accepted)),
                fixtureID
            )
        }
        if ["attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes"].contains(generator.dimension) {
            _ = try MIMEMessageDecoder.decodedAttachments(from: acceptedData)
        }

        let rejectedData = try ProviderFixtureMIMEFixtures.generated(
            generator,
            amount: generator.rejected
        )
        switch generator.dimension {
        case "body_bytes":
            XCTAssertEqual(
                try ProviderFixtureDocumentDecoder.mimeProjection(from: rejectedData).textBody,
                .omittedOversized,
                fixtureID
            )
        case "attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes":
            XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: rejectedData), fixtureID)
        default:
            XCTAssertThrowsError(try ProviderFixtureDocumentDecoder.mimeProjection(from: rejectedData), fixtureID)
        }
    }


    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func repeatedAttachmentMessage(count: Int) -> Data {
        let boundary = "AttachmentLimit"
        var message = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        for index in 0 ..< count {
            message += "--\(boundary)\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(index).bin\"\r\n\r\nx\r\n"
        }
        message += "--\(boundary)--\r\n"
        return Data(message.utf8)
    }

    private static func headerMessage(bytes: Int) -> Data {
        let prefix = "X: "
        return Data((prefix + String(repeating: "a", count: bytes - prefix.utf8.count) + "\r\n\r\nbody").utf8)
    }
}
