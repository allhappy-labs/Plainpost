import XCTest
@testable import PlainpostCore

final class MailPreviewNormalizerTests: XCTestCase {
    func testParagraphBreaksBecomeOneSpace() {
        XCTAssertEqual(
            MailPreviewNormalizer.normalized("Hello,\n\nThe engineer will come"),
            "Hello, The engineer will come"
        )
    }

    func testEveryWhitespaceRunCollapses() {
        XCTAssertEqual(MailPreviewNormalizer.normalized("a \t\r\n  b\u{00A0}\u{00A0}c"), "a b c")
    }

    func testTrimsAndLimitsAfterCollapsing() {
        let text = "  " + String(repeating: "word ", count: 200) + "  "
        let result = MailPreviewNormalizer.normalized(text, limit: 20)
        XCTAssertEqual(result.count, 20)
        XCTAssertFalse(result.hasPrefix(" "))
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(MailPreviewNormalizer.normalized(" \n\n "), "")
    }
}
