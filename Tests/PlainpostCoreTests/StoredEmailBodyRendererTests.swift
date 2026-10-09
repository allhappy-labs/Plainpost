import XCTest
@testable import PlainpostCore

final class StoredEmailBodyRendererTests: XCTestCase {
    func testMalformedMultipartWithoutBoundaryFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                MIME-Version: 1.0\r
                Content-Type: multipart/alternative\r
                \r
                --MissingBoundary\r
                Content-Type: text/plain\r
                \r
                Secret raw body\r
                --MissingBoundary--\r
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testMultipartWithMismatchedBoundaryFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                MIME-Version: 1.0\r
                Content-Type: multipart/alternative; boundary="ExpectedBoundary"\r
                \r
                --DifferentBoundary\r
                Content-Type: text/plain\r
                \r
                Secret raw body\r
                --DifferentBoundary--\r
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testUnsupportedNonTextRootFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                MIME-Version: 1.0\r
                Content-Type: application/octet-stream\r
                Content-Transfer-Encoding: base64\r
                \r
                U2VjcmV0IGJpbmFyeSBwYXlsb2Fk\r
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testMIMELookingHeadersAreNotReturnedRawWhenDecoderHasNoDisplayContent() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                From: sender@example.com\r
                Subject: Stored transport envelope\r
                Content-Disposition: attachment\r
                \r
                Raw transport content\r
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testOrdinaryPlainTextWithParagraphBreakIsPreserved() {
        let text = "Hello from a person.\n\nThis is ordinary plain text."

        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: text,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, text)
        XCTAssertNil(rendered.safeHTML)
    }

    func testMIMEStructuralHeadersWithoutSeparatorFailClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: "MIME-Version: 1.0\r\nContent-Type: multipart/alternative\r\nSecret raw body",
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testSingleEnvelopeHeaderWithSeparatorFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: "Subject: Stored envelope\r\n\r\nRaw transport content",
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testFoldedMixedCaseMIMEHeaderWithLFSeparatorFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                cOnTeNt-TyPe: multipart/alternative;
                 boundary="FoldedBoundary"

                --WrongBoundary
                Secret raw body
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testValidMultipartWithNestedContentTypeHeadersDecodes() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """
                MIME-Version: 1.0\r
                Content-Type: multipart/alternative; boundary="ValidBoundary"\r
                \r
                --ValidBoundary\r
                Content-Type: text/plain; charset=utf-8\r
                \r
                Safe plain body\r
                --ValidBoundary\r
                Content-Type: text/html; charset=utf-8\r
                \r
                <p>Safe HTML body</p>\r
                --ValidBoundary--\r
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "Safe plain body")
        XCTAssertEqual(rendered.safeHTML, "<p>Safe HTML body</p>")
    }

    func testLeadingWhitespaceNoiseBeforeTransportHeadersFailsClosed() {
        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: """

                  noise before headers
                From: sender@example.com
                To: receiver@example.com

                Raw transport content
                """,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, "")
        XCTAssertNil(rendered.safeHTML)
    }

    func testOrdinaryUserParagraphContainingColonIsPreserved() {
        let text = "Reminder: buy milk\n\nThen call home."

        let rendered = StoredEmailBodyRenderer.render(
            plainTextOrMIME: text,
            html: nil
        )

        XCTAssertEqual(rendered.safeText, text)
        XCTAssertNil(rendered.safeHTML)
    }
}
