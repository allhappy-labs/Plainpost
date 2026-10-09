import XCTest
@testable import PlainpostCore

final class InlineImageResolverTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    /// Helsana's Outlook signature: the logo and icon are `cid:` parts.
    func testContentIDReferenceBecomesADataURL() {
        let html = #"<img width="102" src="cid:image001.png@01DD54C4.B9AD52D0" alt="logo"><img src='CID:image002.png@01DD54C4.B9AD52D0'>"#
        let resolved = InlineImageResolver.resolve(html: html, parts: [
            .init(contentID: "<image001.png@01DD54C4.B9AD52D0>", filename: "image001.png", mimeType: "image/png", data: png),
            .init(contentID: "image002.png@01DD54C4.B9AD52D0", filename: "other.png", mimeType: "image/png", data: png),
        ])
        let url = "data:image/png;base64,\(png.base64EncodedString())"
        XCTAssertEqual(resolved, #"<img width="102" src="\#(url)" alt="logo"><img src="\#(url)">"#)
    }

    /// Parts cached before Content-IDs were stored match Outlook's file name.
    func testPartWithoutAContentIDMatchesByOutlookFileName() {
        let html = #"<img src="cid:image003.png@01DD54C4.B9AD52D0">"#
        let resolved = InlineImageResolver.resolve(html: html, parts: [
            .init(contentID: nil, filename: "image003.png", mimeType: "image/png", data: png),
        ])
        XCTAssertFalse(resolved.contains("cid:"))
        XCTAssertTrue(resolved.contains("data:image/png;base64,"))
    }

    func testUnmatchedOrNonImageReferenceIsLeftAlone() {
        let html = #"<img src="cid:missing@x"><img src="cid:doc.pdf@x">"#
        let resolved = InlineImageResolver.resolve(html: html, parts: [
            .init(contentID: "doc.pdf@x", filename: "doc.pdf", mimeType: "application/pdf", data: png),
        ])
        XCTAssertEqual(resolved, html)
    }

    func testAmbiguousFileNameIsNotGuessed() {
        let html = #"<img src="cid:image.png@x">"#
        let resolved = InlineImageResolver.resolve(html: html, parts: [
            .init(contentID: nil, filename: "image.png", mimeType: "image/png", data: png),
            .init(contentID: nil, filename: "image.png", mimeType: "image/png", data: Data([1])),
        ])
        XCTAssertEqual(resolved, html)
    }

    func testOversizedImageStaysUnresolved() {
        let html = #"<img src="cid:big@x">"#
        let big = Data(count: InlineImageResolver.maximumImageBytes + 1)
        let resolved = InlineImageResolver.resolve(html: html, parts: [
            .init(contentID: "big@x", filename: "big.png", mimeType: "image/png", data: big),
        ])
        XCTAssertEqual(resolved, html)
    }
}
