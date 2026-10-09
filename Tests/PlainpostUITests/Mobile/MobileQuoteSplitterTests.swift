import PlainpostCore
import XCTest
@testable import PlainpostUI

final class MobileQuoteSplitterTests: XCTestCase {
    func testTextWithoutQuotesIsWhole() {
        XCTAssertEqual(MobileQuoteSplitter.split("Hi Maria,\nThanks."), .init(visible: "Hi Maria,\nThanks.", quoted: nil))
    }

    func testAngleQuotedLinesFold() {
        let parts = MobileQuoteSplitter.split("Looks good.\n\n> Could you look at section 3\n> Thanks")
        XCTAssertEqual(parts.visible, "Looks good.")
        XCTAssertEqual(parts.quoted, "> Could you look at section 3\n> Thanks")
    }

    func testAttributionLineStartsTheQuote() {
        let parts = MobileQuoteSplitter.split("Sure!\r\nOn Tue, 29 Sep 2026, Maria wrote:\r\n> Lunch?")
        XCTAssertEqual(parts.visible, "Sure!")
        XCTAssertEqual(parts.quoted?.hasPrefix("On Tue"), true)
    }

    /// Ledger Task 5: a wrapped attribution folds entirely, not from its last line.
    func testAWrappedAttributionFoldsEntirely() {
        let text = "Sure!\r\n\r\nOn Tue, 29 Sep 2026 at 10:04, Maria Chen <maria.chen@\r\nexample.test> wrote:\r\n> Lunch?"
        let parts = MobileQuoteSplitter.split(text)
        XCTAssertEqual(parts.visible, "Sure!")
        XCTAssertEqual(parts.quoted?.hasPrefix("On Tue, 29 Sep 2026"), true, parts.quoted ?? "")
    }

    func testAThreeLineAttributionFoldsEntirely() {
        let text = "Sure!\nOn Tue, 29 Sep 2026 at 10:04,\nMaria Chen\n<maria.chen@example.test> wrote:\n> Lunch?"
        XCTAssertEqual(MobileQuoteSplitter.split(text).visible, "Sure!")
    }

    func testAWroteLineWithoutAnOnLineAboveItIsNotAnAttribution() {
        let text = "Here is what she wrote:\nthe plan works."
        XCTAssertNil(MobileQuoteSplitter.split(text).quoted)
        let paragraph = "On Monday we met.\n\nThen she wrote:\nhello"
        XCTAssertNil(MobileQuoteSplitter.split(paragraph).quoted, "a blank line ends the attribution")
    }

    func testAnAllQuoteBodyStaysWhole() {
        XCTAssertNil(MobileQuoteSplitter.split("> only a quote").quoted)
    }

    func testUnquotedPlainTextKeepsItsOwnDisplay() {
        XCTAssertNil(MobileQuoteSplitter.fold(RenderedEmailBody(kind: .plainText, safeText: "Hi Maria,\nThanks.", blockedRemoteImageURLs: [])))
    }

    func testHTMLKeepsItsOwnDisplay() {
        XCTAssertNil(MobileQuoteSplitter.fold(RenderedEmailBody(kind: .html, safeText: "Sure!\n> Lunch?", safeHTML: "<p>Sure!</p>", blockedRemoteImageURLs: [])))
    }

    func testDeferredMessageWithoutAQuoteKeepsItsOwnDisplay() async {
        let message = Self.deferredMessage(raw: "Hi Maria,<!-- tracking -->\n*|MC_PREVIEW|*\nThanks.")
        let fold = await MobileQuoteSplitter.fold(message, store: DeferredEmailBodyRenderStore())
        XCTAssertNil(fold)
    }

    func testDeferredMessageFoldsTheRenderedBodyNotTheRawFallback() async {
        let message = Self.deferredMessage(raw: "Looks good.<!-- tracking -->\n*|MC_PREVIEW|*\n\n\n   \n> earlier    text")
        let fold = await MobileQuoteSplitter.fold(message, store: DeferredEmailBodyRenderStore())
        XCTAssertEqual(fold?.body.safeText, "Looks good.")
        XCTAssertEqual(fold?.body.kind, .plainText)
        XCTAssertEqual(fold?.quoted, "> earlier text")
    }

    private static func deferredMessage(raw: String) -> ThreadMessageModel {
        ThreadMessageModel(
            id: "m1",
            sender: "maria@example.test",
            deferredBody: .plainText(raw),
            fallbackText: raw,
            blockedRemoteImageURLs: []
        )
    }
}
