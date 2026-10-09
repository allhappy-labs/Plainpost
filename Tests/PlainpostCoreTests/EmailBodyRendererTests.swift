import XCTest
@testable import PlainpostCore

final class EmailBodyRendererTests: XCTestCase {
    func testPlainTextBodyHasNoBlockedRemoteImages() {
        let rendered = EmailBodyRenderer.render(.plainText("Hello Alice\nCan you meet Tuesday?"))

        XCTAssertEqual(rendered.kind, .plainText)
        XCTAssertEqual(rendered.safeText, "Hello Alice\nCan you meet Tuesday?")
        XCTAssertEqual(rendered.blockedRemoteImageURLs, [])
    }

    func testSanitizesHTMLAndBlocksRemoteImages() {
        let input = """
        <html>
          <head>
            <style>.tracking { display: none; }</style>
            <script>alert("x")</script>
          </head>
          <body>
            <p>Hello <strong>Alice</strong></p>
            <img src="https://tracker.example/pixel.png">
            <img src="cid:inline-image">
          </body>
        </html>
        """

        let rendered = EmailBodyRenderer.render(.html(input))

        XCTAssertEqual(rendered.kind, .html)
        XCTAssertTrue(rendered.safeText.contains("Hello Alice"))
        XCTAssertFalse(rendered.safeText.contains("script"))
        XCTAssertFalse(rendered.safeText.contains("tracking"))
        XCTAssertFalse(rendered.safeText.contains("tracker.example"))
        XCTAssertEqual(rendered.blockedRemoteImageURLs, ["https://tracker.example/pixel.png"])
        XCTAssertTrue(rendered.safeHTML?.contains("<style>") == true)
        XCTAssertTrue(rendered.safeHTML?.contains("<img src=\"https://tracker.example/pixel.png\">") == true)
        XCTAssertFalse(rendered.safeHTML?.contains("<script") == true)
    }

    func testRemovesHTMLCommentsAndTemplateTokensWhilePreservingParagraphs() {
        let rendered = EmailBodyRenderer.render(
            .html("<!-- 96 *|MC:SUBJECT|* --> <p>Hello Alice</p><p>Second paragraph</p>")
        )

        XCTAssertFalse(rendered.safeText.contains("MC:SUBJECT"))
        XCTAssertFalse(rendered.safeText.contains("-->"))
        XCTAssertEqual(rendered.safeText, "Hello Alice\n\nSecond paragraph")
        XCTAssertEqual(rendered.safeHTML, " <p>Hello Alice</p><p>Second paragraph</p>")
    }

    func testRemovesGeneratedMarkupFromPlainTextWhilePreservingParagraphs() {
        let rendered = EmailBodyRenderer.render(
            .plainText("Intro\n\n<!-- hidden metadata -->\n96 *|MC:SUBJECT|*\nMessage body")
        )

        XCTAssertFalse(rendered.safeText.contains("hidden metadata"))
        XCTAssertFalse(rendered.safeText.contains("MC:SUBJECT"))
        XCTAssertEqual(rendered.safeText, "Intro\n\nMessage body")
    }
}
