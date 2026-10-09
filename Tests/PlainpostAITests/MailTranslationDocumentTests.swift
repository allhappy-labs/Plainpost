import XCTest
import PlainpostAI
import PlainpostCore

final class MailTranslationDocumentTests: XCTestCase {
    func testContractVersionAndHTMLTransformationPreserveProtectedContent() throws {
        let html = #"""
        <article data-id="m1"><p>Hallo <a href="https://example.com?q=1&amp;x=2">Welt</a>.</p>
        <pre><code>if (x &lt; 2) { keep(); }</code></pre>
        <img src="cid:logo"><p>max@example.com</p></article>
        """#

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(MailTranslationContract.version, "message-translation-v2")
        XCTAssertEqual(prepared.bodyKind, .html)
        XCTAssertEqual(prepared.segments.map(\.text), ["Hallo ", "Welt", "."])

        let output = try prepared.reconstruct([
            .init(id: prepared.segments[0].id, translation: "Hello "),
            .init(id: prepared.segments[1].id, translation: #"<script>alert(1)</script> & goodbye"#),
            .init(id: prepared.segments[2].id, translation: "."),
        ])

        XCTAssertTrue(output.safeHTML?.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; goodbye") == true)
        XCTAssertTrue(output.safeHTML?.contains(#"href="https://example.com?q=1&amp;x=2""#) == true)
        XCTAssertTrue(output.safeHTML?.contains(#"<pre><code>if (x &lt; 2) { keep(); }</code></pre>"#) == true)
        XCTAssertTrue(output.safeHTML?.contains(#"<img src="cid:logo">"#) == true)
    }

    func testPlainTextWhitespaceOnlyBodyHasNoMutableSegments() throws {
        let rendered = RenderedEmailBody(
            kind: .plainText,
            safeText: "\n \t\n",
            blockedRemoteImageURLs: []
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertTrue(prepared.segments.isEmpty)
        XCTAssertTrue(prepared.batches(maxUTF8Bytes: 100).isEmpty)
        XCTAssertEqual(try prepared.reconstruct([]).safeText, "\n \t\n")
    }

    func testReconstructionPreservesEverySourceByteOutsideReplacedSegments() throws {
        let html = """
        <!doctype html><!-- immutable > comment -->
          <pre><code>*|FNAME|*  raw
        code</code></pre><p>Hello</p>
        <img src="https://tracker.example/pixel.png">
        """
        let rendered = RenderedEmailBody(
            kind: .html,
            safeText: "Hello",
            safeHTML: html,
            blockedRemoteImageURLs: ["https://tracker.example/pixel.png"]
        )

        let prepared = try MailTranslationDocument.prepare(rendered)
        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "Hi  *|RECIPIENT|*"),
        ])

        XCTAssertEqual(
            output.safeHTML,
            """
            <!doctype html><!-- immutable > comment -->
              <pre><code>*|FNAME|*  raw
            code</code></pre><p>Hi  *|RECIPIENT|*</p>
            <img src="https://tracker.example/pixel.png">
            """
        )
        XCTAssertEqual(
            output.blockedRemoteImageURLs,
            ["https://tracker.example/pixel.png"]
        )
    }

    func testSingleLineGeneratedMarkerCannotEraseAncillaryTextOrTrackerDiscovery() throws {
        let html = #"<p>Hello</p><img src="https://tracker.example/pixel.png">"#
        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "*|RECIPIENT|*"),
        ])

        XCTAssertEqual(
            output.safeHTML,
            #"<p>*|RECIPIENT|*</p><img src="https://tracker.example/pixel.png">"#
        )
        XCTAssertEqual(output.safeText, "*|RECIPIENT|*")
        XCTAssertEqual(
            output.blockedRemoteImageURLs,
            ["https://tracker.example/pixel.png"]
        )
    }

    func testRawURLsAndEmailAddressesRemainImmutableWhileAdjacentProseIsSegmented() throws {
        let rendered = EmailBodyRenderer.render(
            .html("<p>Visit https://example.com/a?x=1&amp;y=2 or max@example.com today.</p>")
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(prepared.segments.map(\.id), ["segment-0", "segment-1", "segment-2"])
        XCTAssertEqual(prepared.segments.map(\.text), ["Visit ", " or ", " today."])

        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "Besuche "),
            .init(id: "segment-1", translation: " oder "),
            .init(id: "segment-2", translation: " heute."),
        ])
        XCTAssertEqual(
            output.safeHTML,
            "<p>Besuche https://example.com/a?x=1&amp;y=2 oder max@example.com heute.</p>"
        )
    }

    func testEntityEncodedURLsAndEmailAddressesNeverEnterModelSegmentsAndRemainByteExact() throws {
        let html = """
        <p>Contact max&#64;example.com or visit https&#58;//example.com/a?x=1&amp;y=2 now.</p>
        """

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            ["Contact ", " or visit ", " now."]
        )
        XCTAssertFalse(
            prepared.segments.contains {
                $0.text.contains("max")
                    || $0.text.contains("example.com")
                    || $0.text.contains("https")
            }
        )

        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "Schreibe an "),
            .init(id: "segment-1", translation: " oder besuche "),
            .init(id: "segment-2", translation: " jetzt."),
        ])

        XCTAssertEqual(
            output.safeHTML,
            """
            <p>Schreibe an max&#64;example.com oder besuche https&#58;//example.com/a?x=1&amp;y=2 jetzt.</p>
            """
        )
    }

    func testHexNamedAndSemicolonlessNumericEntitiesCannotExposeProtectedAddresses() throws {
        let html = """
        <p>Use max&#x40;example.com, max&commat;example.com, max&#64example.com, and https&colon;//example.com.</p>
        """
        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            ["Use ", ", ", ", ", ", and "]
        )

        let output = try prepared.reconstruct(
            prepared.segments.map {
                AITranslatedSegment(id: $0.id, translation: "[t]")
            }
        )
        XCTAssertTrue(output.safeHTML?.contains("max&#x40;example.com") == true)
        XCTAssertTrue(output.safeHTML?.contains("max&commat;example.com") == true)
        XCTAssertTrue(output.safeHTML?.contains("max&#64example.com") == true)
        XCTAssertTrue(output.safeHTML?.contains("https&colon;//example.com") == true)
    }

    func testPlainTextFencedInlineAndIndentedCodeNeverEnterModelSegmentsAndRemainByteExact() throws {
        let source = """
        Translate this.
        ```swift
        let endpoint = "https://code.example"
        ```
        Keep `max@example.com` inline.
        Keep ```triple-inline-secret with ` marker``` unchanged.
            curl https://indented.example
        Translate that.
        """
        let prepared = try MailTranslationDocument.prepare(
            RenderedEmailBody(
                kind: .plainText,
                safeText: source,
                blockedRemoteImageURLs: []
            )
        )

        let modelInput = prepared.segments.map(\.text).joined()
        XCTAssertFalse(modelInput.contains("let endpoint"))
        XCTAssertFalse(modelInput.contains("max@example.com"))
        XCTAssertFalse(modelInput.contains("triple-inline-secret"))
        XCTAssertFalse(modelInput.contains("curl https://indented.example"))

        let output = try prepared.reconstruct(
            prepared.segments.map {
                AITranslatedSegment(id: $0.id, translation: "[translated]")
            }
        )

        XCTAssertTrue(output.safeText.contains(
            """
            ```swift
            let endpoint = "https://code.example"
            ```
            """
        ))
        XCTAssertTrue(output.safeText.contains("`max@example.com`"))
        XCTAssertTrue(output.safeText.contains(
            "```triple-inline-secret with ` marker```"
        ))
        XCTAssertTrue(output.safeText.contains("    curl https://indented.example"))
    }

    func testPlainTextTranslationPreservesRawAmpersandsAndAngleBrackets() throws {
        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.plainText("Hallo"))
        )

        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "R&D <ready> > done"),
        ])

        XCTAssertEqual(output.safeText, "R&D <ready> > done")
    }

    func testQuotedGreaterThanInAttributeDoesNotBecomeMutableText() throws {
        let html = #"<p title="one > zero" data-note='two > one'>Translate me</p>"#

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(prepared.segments.map(\.text), ["Translate me"])
        XCTAssertEqual(
            try prepared.reconstruct([.init(id: "segment-0", translation: "Übersetze mich")]).safeHTML,
            #"<p title="one > zero" data-note='two > one'>Übersetze mich</p>"#
        )
    }

    func testCommentsAndDoctypeRemainImmutable() throws {
        let html = #"<!doctype html><!-- never > translate --><p>Hello</p>"#
        let rendered = RenderedEmailBody(
            kind: .html,
            safeText: "Hello",
            safeHTML: html,
            blockedRemoteImageURLs: []
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(prepared.segments.map(\.text), ["Hello"])
        XCTAssertEqual(
            try prepared.reconstruct([.init(id: "segment-0", translation: "Hallo")]).safeHTML,
            #"<!doctype html><!-- never > translate --><p>Hallo</p>"#
        )
    }

    func testVoidElementsRemainImmutableAndDoNotSuppressFollowingText() throws {
        let html = #"<p>A<br>B<img src="cid:logo">C<hr>D</p>"#

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(prepared.segments.map(\.text), ["A", "B", "C", "D"])
        let output = try prepared.reconstruct([
            .init(id: "segment-0", translation: "1"),
            .init(id: "segment-1", translation: "2"),
            .init(id: "segment-2", translation: "3"),
            .init(id: "segment-3", translation: "4"),
        ])
        XCTAssertEqual(output.safeHTML, #"<p>1<br>2<img src="cid:logo">3<hr>4</p>"#)
    }

    func testPreformattedEmailProseTranslatesWhileExecutableAndCodeContentStayProtected() throws {
        let html = """
        <p>Before</p><style>.secret { color: red; }</style><script>steal()</script>\
        <pre>raw <b>code</b></pre><code>inline()</code><p>After</p>
        """
        let rendered = RenderedEmailBody(
            kind: .html,
            safeText: "Before After",
            safeHTML: html,
            blockedRemoteImageURLs: []
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(prepared.segments.map(\.text), ["Before", "raw ", "code", "After"])
        let modelInput = prepared.segments.map(\.text).joined()
        XCTAssertFalse(modelInput.contains(".secret"))
        XCTAssertFalse(modelInput.contains("steal()"))
        XCTAssertFalse(modelInput.contains("inline()"))
    }

    func testMetadataAndEmbeddedContextsNeverBecomeSegmentsAndRemainImmutable() throws {
        let html = """
        <head><title>Title secret</title><template>Template secret</template></head>\
        <svg><text>Vector secret</text></svg><math><mi>Math secret</mi></math>\
        <canvas>Canvas fallback</canvas><audio>Audio fallback</audio>\
        <video>Video fallback</video><picture>Picture fallback</picture>\
        <iframe>Frame fallback</iframe><object>Object fallback</object>\
        <metadata>Metadata secret</metadata>\
        <p>Visible prose</p>
        """
        let rendered = RenderedEmailBody(
            kind: .html,
            safeText: "Visible prose",
            safeHTML: html,
            blockedRemoteImageURLs: []
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(prepared.segments.map(\.text), ["Visible prose"])
        XCTAssertEqual(
            try prepared.reconstruct([.init(id: "segment-0", translation: "Sichtbarer Text")]).safeHTML,
            """
            <head><title>Title secret</title><template>Template secret</template></head>\
            <svg><text>Vector secret</text></svg><math><mi>Math secret</mi></math>\
            <canvas>Canvas fallback</canvas><audio>Audio fallback</audio>\
            <video>Video fallback</video><picture>Picture fallback</picture>\
            <iframe>Frame fallback</iframe><object>Object fallback</object>\
            <metadata>Metadata secret</metadata>\
            <p>Sichtbarer Text</p>
            """
        )
    }

    func testAllURISchemesRemainImmutable() throws {
        let html = "<p>Before ftp://files.example.test/a custom+safe:value cid:part-1 After</p>"

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            ["Before ", " After"]
        )
    }

    func testQuotedLiteralAndInternationalizedEmailAddressesRemainImmutable() throws {
        let html = #"<p>Contact "quoted local"@[IPv6:2001:db8::1], δοκιμή@παράδειγμα.δοκιμή, user@[127.0.0.1] now.</p>"#

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            [
                "Contact ",
                ", ",
                " now.",
            ]
        )
    }

    func testSchemeLessAndInternationalizedURLsRemainImmutable() throws {
        let html = "<p>See www.example.com/a?x=1 and beispiel.vermögensberatung/path and 例子.公司/路径 now.</p>"

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            ["See ", " and ", " and ", " now."]
        )
    }

    func testEscapedQuotedAndBroadUnicodeEmailLocalPartsRemainImmutable() throws {
        let html = #"<p>Contact "escaped\" quote"@example.com, o'hara@example.com, 💌@例子.公司 now.</p>"#

        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html(html))
        )

        XCTAssertEqual(
            prepared.segments.map(\.text),
            [
                "Contact ",
                ", ",
                ", ",
                " now.",
            ]
        )
    }

    func testMalformedUnterminatedMarkupFailsClosed() throws {
        let html = #"<p>Visible</p><a title="unterminated > hidden text"#
        let rendered = RenderedEmailBody(
            kind: .html,
            safeText: "Visible hidden text",
            safeHTML: html,
            blockedRemoteImageURLs: []
        )

        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(prepared.segments.map(\.text), ["Visible"])
    }

    func testBatchesUseUTF8ByteLimitsAndKeepOversizedSingleSegments() throws {
        let rendered = EmailBodyRenderer.render(
            .html("<p>éé</p><p>abc</p><p>🙂</p><p>oversized</p>")
        )
        let prepared = try MailTranslationDocument.prepare(rendered)

        XCTAssertEqual(
            prepared.batches(maxUTF8Bytes: 7).map { $0.map(\.id) },
            [["segment-0", "segment-1"], ["segment-2"], ["segment-3"]]
        )
        XCTAssertEqual(
            prepared.batches(maxUTF8Bytes: 2).map { $0.map(\.id) },
            [["segment-0"], ["segment-1"], ["segment-2"], ["segment-3"]]
        )
        XCTAssertFalse(prepared.batches(maxUTF8Bytes: 0).contains(where: \.isEmpty))
    }

    func testReconstructionAcceptsOutOfOrderCompleteTranslations() throws {
        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html("<p>First</p><p>Second</p>"))
        )

        let output = try prepared.reconstruct([
            .init(id: "segment-1", translation: "Zweite"),
            .init(id: "segment-0", translation: "Erste"),
        ])

        XCTAssertEqual(output.safeHTML, "<p>Erste</p><p>Zweite</p>")
    }

    func testReconstructionRejectsMissingDuplicateAndUnexpectedIDs() throws {
        let prepared = try MailTranslationDocument.prepare(
            EmailBodyRenderer.render(.html("<p>First</p><p>Second</p>"))
        )

        XCTAssertThrowsError(
            try prepared.reconstruct([.init(id: "segment-0", translation: "Erste")])
        ) { error in
            XCTAssertEqual(error as? MailTranslationDocumentError, .invalidSegmentIdentity)
        }
        XCTAssertThrowsError(
            try prepared.reconstruct([
                .init(id: "segment-0", translation: "Erste"),
                .init(id: "segment-0", translation: "Noch einmal"),
            ])
        ) { error in
            XCTAssertEqual(error as? MailTranslationDocumentError, .invalidSegmentIdentity)
        }
        XCTAssertThrowsError(
            try prepared.reconstruct([
                .init(id: "segment-0", translation: "Erste"),
                .init(id: "unexpected", translation: "Zweite"),
            ])
        ) { error in
            XCTAssertEqual(error as? MailTranslationDocumentError, .invalidSegmentIdentity)
        }
    }
}
