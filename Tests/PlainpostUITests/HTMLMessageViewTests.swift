import SwiftUI
import WebKit
import Network
import PlainpostCore
import XCTest
#if os(macOS)
import AppKit

private final class TrackingScrollView: NSScrollView {
    private(set) var receivedWheelEvent = false

    override func scrollWheel(with event: NSEvent) {
        receivedWheelEvent = true
    }
}
#endif
@testable import PlainpostUI

final class HTMLMessageViewTests: XCTestCase {
    @MainActor
    func testCoordinatorCoalescesTwentyChangesToOneActiveAndLatestPending() async throws {
        let preparation = GatedHTMLPreparation()
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: .constant(180), prepareDocument: preparation.start
        )
        let webView = RecordingHTMLWebView()
        coordinator.load(html: "<p>Initial</p>", allowsRemoteContent: true, in: webView)
        let firstOwner = try XCTUnwrap(coordinator.preparationTask)
        for index in 1...20 {
            coordinator.load(
                html: "<p>Selection \(index)</p><img src=\"https://example.com/image.png\">",
                allowsRemoteContent: index.isMultiple(of: 3),
                colorScheme: index.isMultiple(of: 2) ? .dark : .light,
                in: webView
            )
        }
        XCTAssertEqual(preparation.inputs.count, 1, "Pending selections must not start parses")
        XCTAssertEqual(preparation.maximumActive, 1)
        preparation.releaseFirst()
        await firstOwner.value
        await coordinator.preparationTask?.value

        XCTAssertEqual(preparation.inputs.count, 2, "Only first and latest input may be prepared")
        XCTAssertEqual(preparation.maximumActive, 1)
        XCTAssertEqual(preparation.inputs.last?.html, "<p>Selection 20</p><img src=\"https://example.com/image.png\">")
        XCTAssertEqual(webView.documents.count, 1)
        let document = try XCTUnwrap(webView.documents.last)
        XCTAssertTrue(document.contains("Selection 20"))
        XCTAssertTrue(document.contains("<meta name=\"plainpost-appearance\" content=\"dark\">"))
        XCTAssertTrue(document.contains("data-mail-remote-src=\"https://example.com/image.png\""))
        XCTAssertFalse(document.contains("<img src=\"https://example.com/image.png\""))
        XCTAssertTrue(document.contains("script-src 'none'"))

        // Same HTML with an explicit load-once policy change must prepare again.
        coordinator.load(html: preparation.inputs.last!.html, allowsRemoteContent: true, colorScheme: .dark, in: webView)
        await coordinator.preparationTask?.value
        XCTAssertEqual(preparation.inputs.count, 3)
        XCTAssertTrue(webView.documents.last!.contains("<img src=\"https://example.com/image.png\""))
        Self.dismantle(webView, coordinator: coordinator)
    }

    @MainActor
    func testDismantleDropsPendingClosesAdmissionAndPreventsLatePublication() async throws {
        let preparation = GatedHTMLPreparation()
        let coordinator = HTMLMessageView.Coordinator(contentHeight: .constant(180), prepareDocument: preparation.start)
        let webView = RecordingHTMLWebView()
        coordinator.load(html: "<p>Active</p>", allowsRemoteContent: false, in: webView)
        let owner = try XCTUnwrap(coordinator.preparationTask)
        coordinator.load(html: "<p>Pending</p>", allowsRemoteContent: false, in: webView)
        Self.dismantle(webView, coordinator: coordinator)
        coordinator.load(html: "<p>After teardown</p>", allowsRemoteContent: true, in: webView)
        XCTAssertEqual(preparation.inputs.map(\.html), ["<p>Active</p>"])
        preparation.releaseFirst()
        await owner.value
        await coordinator.preparationTask?.value
        XCTAssertTrue(webView.documents.isEmpty)
        XCTAssertEqual(preparation.inputs.map(\.html), ["<p>Active</p>"])
    }

    @MainActor
    func testDismantleReleasesCoordinatorAndWebViewWhilePreparationIsHeld() async throws {
        let preparation = GatedHTMLPreparation()
        let references = HTMLLifetimeReferences()
        let owner = try autoreleasepool {
            var coordinator: HTMLMessageView.Coordinator? = HTMLMessageView.Coordinator(
                contentHeight: .constant(180), prepareDocument: preparation.start
            )
            references.coordinator = coordinator
            let webView = HTMLMessageView.makeWebView(coordinator: coordinator!)
            references.webView = webView
            coordinator!.load(html: "<p>Held</p>", allowsRemoteContent: false, in: webView)
            let owner = try XCTUnwrap(coordinator!.preparationTask)
            coordinator!.load(html: "<p>Pending</p>", allowsRemoteContent: false, in: webView)
            Self.dismantle(webView, coordinator: coordinator!)
            coordinator = nil
            // The still-live WebKit content controller must no longer own the coordinator.
            XCTAssertNil(references.coordinator)
            return owner
        }
        XCTAssertNil(references.webView)
        preparation.releaseFirst()
        await owner.value
        XCTAssertEqual(preparation.inputs.count, 1)
    }

    func testLargeSyntheticNewsletterPreparationProfile() {
        let html = Self.largeNewsletter
        var samples: [[String: Any]] = []
        for allowsRemoteContent in [false, true] {
            for index in 0..<5 {
                let start = ContinuousClock.now
                let document = HTMLMessageDocument.document(
                    html: html, allowsRemoteContent: allowsRemoteContent,
                    colorScheme: index.isMultiple(of: 2) ? .light : .dark
                )
                let elapsed = start.duration(to: .now)
                XCTAssertTrue(document.contains("Newsletter finish"))
                XCTAssertTrue(document.contains("script-src 'none'"))
                XCTAssertEqual(document.contains("data-mail-remote-src="), !allowsRemoteContent)
                samples.append([
                    "remote_content": allowsRemoteContent, "input_bytes": html.utf8.count,
                    "output_bytes": document.utf8.count,
                    "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                ])
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
        print("TASK10_NEWSLETTER_PREPARATION " + String(decoding: data, as: UTF8.self))
    }

    @MainActor
    func testLargeSyntheticNewsletterLoadsThroughCoordinatorInWebKit() async throws {
        let coordinator = HTMLMessageView.Coordinator(contentHeight: .constant(180))
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        defer { Self.dismantle(webView, coordinator: coordinator) }
        let html = Self.largeNewsletter
        let start = ContinuousClock.now
        coordinator.load(html: html, allowsRemoteContent: false, colorScheme: .dark, in: webView)
        try await waitForText("Newsletter finish", in: webView)
        let remoteSource = try await webView.evaluateJavaScript("document.querySelector('img').getAttribute('src')")
        XCTAssertTrue(remoteSource is NSNull)
        let elapsed = start.duration(to: .now)
#if os(macOS)
        let platform = "macOS-WebKit"
#else
        let platform = "iOS-WebKit"
#endif
        print("TASK10_NEWSLETTER_WEBKIT platform=\(platform) input_bytes=\(html.utf8.count) seconds=\(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
    }

    private static var largeNewsletter: String {
        "<html><head><style>.row { background-image: url(https://example.com/background.jpg); }</style></head><body>"
        + String(repeating: "<section class=\"row\"><h2>Newsletter article</h2><p>Public synthetic newsletter content for preparation profiling.</p><img src=\"https://example.com/image.png\" srcset=\"https://example.com/image2.png 2x\"></section>", count: 6_000)
        + "<p>Newsletter finish</p></body></html>"
    }

    @MainActor
    private static func dismantle(_ webView: WKWebView, coordinator: HTMLMessageView.Coordinator) {
#if os(macOS)
        HTMLMessageView.dismantleNSView(webView, coordinator: coordinator)
#else
        HTMLMessageView.dismantleUIView(webView, coordinator: coordinator)
#endif
    }

    @MainActor
    func testActivatedExternalLinkCallsCallbackAndCancelsNavigation() {
        var contentHeight: CGFloat = 180
        var openedURLs: [URL] = []
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { contentHeight }, set: { contentHeight = $0 }),
            onExternalURL: { openedURLs.append($0) }
        )
        let url = URL(string: "https://example.com/receipt")!

        let policy = coordinator.externalLinkPolicy(for: url)

        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(openedURLs, [url])
    }

    func testBlockedPolicyGovernsFragmentsAndLeadingDocumentTags() throws {
        // These inputs remain accepted Core HTML, including real tag attributes
        // containing tag-looking text. The generated policy must precede content.
        let inputs = [
            "<header>Letter</header><img src=http://127.0.0.1:1/pixel>",
            "<html-prefix>Letter</html-prefix><img src=http://127.0.0.1:1/pixel>",
            "<head-prefix>Letter</head-prefix><img src=http://127.0.0.1:1/pixel>",
            "<!doctype html><HTML lang='en' title='> <head>'><HEAD title=\"> <html>\"></HEAD><body><img src=http://127.0.0.1:1/pixel></body></HTML>",
            "<html title=\"> <head>\"><body><img src=http://127.0.0.1:1/pixel></body></html>",
            "<body><img src=http://127.0.0.1:1/pixel><head></head></body>"
        ]
        for input in inputs {
            let safeHTML = try XCTUnwrap(EmailBodyRenderer.render(.html(input)).safeHTML)
            let document = HTMLMessageDocument.document(html: safeHTML, allowsRemoteContent: false)
            let policy = try XCTUnwrap(document.range(of: "img-src data: cid:"), input)
            let image = try XCTUnwrap(document.range(of: "<img"), input)
            XCTAssertLessThan(policy.lowerBound, image.lowerBound, input)
            XCTAssertFalse(document.contains("img-src http: https:"), input)
            XCTAssertTrue(document.contains("script-src 'none'"), input)
        }
    }

    @MainActor
    func testBlockedUnquotedAndHeaderImagesNeverReachOwnedLoopback() async throws {
        let receiver = try HTMLLoopbackReceiver()
        defer { receiver.stop() }
        await fulfillment(of: [receiver.ready], timeout: 5)
        let port = try XCTUnwrap(receiver.port, receiver.failureDescription)
        // A decoded image and a recorded GET acknowledge that this exact private
        // WebKit path can reach the owned receiver before any negative assertion.
        let allowed = "http://127.0.0.1:\(port)/allowed"
        let positive = try await completedPage(html: "<img src=\(allowed)>", allowsRemoteContent: true)
        XCTAssertEqual(positive.loadedImages, 1)
        XCTAssertEqual(receiver.requests(for: "/allowed"), 1)

        let forms: [(String, (String) -> String)] = [
            ("fragment", { "<img src=\($0)>" }),
            ("header", { "<header>Letter</header><img src=\($0)>" }),
            ("full", { "<!doctype html><html><head></head><body><img src=\($0)></body></html>" }),
            ("quoted-attributes", { "<html title='> <head>'><head title=\"> <html>\"></head><body><img src=\($0)></body></html>" })
        ]
        for (name, form) in forms {
            let path = "/blocked-\(name)"
            let page = try await completedPage(
                html: form("http://127.0.0.1:\(port)\(path)"), allowsRemoteContent: false
            )
            XCTAssertEqual(page.loadedImages, 0, name)
            XCTAssertEqual(receiver.requests(for: path), 0, name)
            print("FINAL_HTML_LOOPBACK case=\(name) page_complete=true images_complete=true requests=\(receiver.requests(for: path)) loaded_images=\(page.loadedImages)")
        }
        print("FINAL_HTML_LOOPBACK positive_control_requests=\(receiver.requests(for: "/allowed"))")
    }

    @MainActor
    func testBlockedQuotedCSSAndSrcsetKeepDataContentAndLoadOnceWorks() async throws {
        let receiver = try HTMLLoopbackReceiver()
        defer { receiver.stop() }
        await fulfillment(of: [receiver.ready], timeout: 5)
        let port = try XCTUnwrap(receiver.port, receiver.failureDescription)
        let remote = "http://127.0.0.1:\(port)/blocked-variants"
        let dataImage = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let html = """
        <header>Letter</header>
        <img src="\(remote)">
        <img srcset="\(remote) 1x">
        <div style="background-image: url(\(remote))">Background</div>
        <img src="\(dataImage)">
        """
        let blocked = try await completedPage(html: html, allowsRemoteContent: false)
        XCTAssertEqual(blocked.loadedImages, 1, "The explicitly permitted data image still renders")
        XCTAssertEqual(receiver.requests(for: "/blocked-variants"), 0)
        let safeHTML = try XCTUnwrap(EmailBodyRenderer.render(.html(html)).safeHTML)
        let loadOnce = HTMLMessageDocument.loadOnceDocument(html: safeHTML)
        XCTAssertTrue(loadOnce.contains("img-src http: https: data: cid:"))
        XCTAssertTrue(HTMLMessageDocument.document(html: "<img src=cid:part>", allowsRemoteContent: false).contains("img-src data: cid:"))
        let allowed = try await completedPage(html: "<img src=\(remote)>", allowsRemoteContent: true)
        XCTAssertEqual(allowed.loadedImages, 1)
        XCTAssertEqual(receiver.requests(for: "/blocked-variants"), 1)
        print("FINAL_HTML_LOOPBACK quoted_css_srcset_blocked=true data_image_loaded=true load_once_requests=1")
    }

    private struct CompletedHTMLPage {
        let loadedImages: Int
    }

    @MainActor
    private func completedPage(html: String, allowsRemoteContent: Bool) async throws -> CompletedHTMLPage {
        let safeHTML = try XCTUnwrap(EmailBodyRenderer.render(.html(html)).safeHTML)
        let coordinator = HTMLMessageView.Coordinator(contentHeight: .constant(180))
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        let completion = HTMLPageCompletion()
        webView.navigationDelegate = completion
        defer { Self.dismantle(webView, coordinator: coordinator) }
        coordinator.load(html: safeHTML, allowsRemoteContent: allowsRemoteContent, in: webView)
        await fulfillment(of: [completion.finished], timeout: 15)
        if let error = completion.error { throw error }
        let ready = try await webView.evaluateJavaScript("document.readyState") as? String
        let allImagesComplete = try await webView.evaluateJavaScript("Array.from(document.images).every(image => image.complete)") as? Bool
        XCTAssertEqual(ready, "complete", "Navigation must acknowledge finished page loading")
        XCTAssertEqual(allImagesComplete, true, "Every image must acknowledge load or error before checking requests")
        let count = try await webView.evaluateJavaScript("Array.from(document.images).filter(image => image.naturalWidth > 0).length") as? Int
        return CompletedHTMLPage(loadedImages: try XCTUnwrap(count))
    }

    func testDefaultBlockedDocumentKeepsRemoteImageSourceInert() {
        let document = HTMLMessageDocument.document(
            html: "<img src=\"https://example.com/tracker.png\">",
            allowsRemoteContent: false
        )

        XCTAssertTrue(document.contains("data-mail-remote-src=\"https://example.com/tracker.png\""))
        XCTAssertFalse(document.contains("<img src=\"https://example.com/tracker.png\""))
    }

    func testLoadOnceDocumentRetainsCSPAndScriptsDisabled() {
        let document = HTMLMessageDocument.loadOnceDocument(
            html: "<p>Receipt</p><img src=\"https://example.com/receipt.png\">"
        )

        XCTAssertTrue(document.contains("img-src http: https: data: cid:"))
        XCTAssertTrue(document.contains("script-src 'none'"))
        XCTAssertTrue(document.contains("<img src=\"https://example.com/receipt.png\""))
    }

    func testBlockedDocumentMakesRemoteResourcesInertUntilRequested() {
        let document = HTMLMessageDocument.document(
            html: "<html><head><style>p { background-image: url(https://example.com/background.jpg); }</style></head><body><img src=\"https://example.com/image.jpg\"></body></html>",
            allowsRemoteContent: false
        )

        XCTAssertTrue(document.contains("style-src 'unsafe-inline'"))
        XCTAssertTrue(document.contains("img-src data: cid:"))
        XCTAssertTrue(document.contains("data-mail-remote-src=\"https://example.com/image.jpg\""))
        XCTAssertFalse(document.contains("<img src=\"https://example.com/image.jpg\""))
        XCTAssertFalse(document.contains("url(https://example.com/background.jpg)"))
    }

    func testEnabledDocumentAllowsRemoteImagesAndKeepsScriptsDisabled() {
        let document = HTMLMessageDocument.document(
            html: "<p>Listing</p><img src=\"https://example.com/image.jpg\">",
            allowsRemoteContent: true
        )

        XCTAssertTrue(document.contains("img-src http: https: data: cid:"))
        XCTAssertTrue(document.contains("script-src 'none'"))
        XCTAssertTrue(document.contains("<body><p>Listing</p>"))
    }

    func testDocumentProvidesReadableLightAndDarkThemeDefaults() {
        let light = HTMLMessageDocument.document(
            html: "<h1>Letter</h1><p>Hello</p>",
            allowsRemoteContent: false,
            colorScheme: .light
        )
        let dark = HTMLMessageDocument.document(
            html: "<h1>Letter</h1><p>Hello</p>",
            allowsRemoteContent: false,
            colorScheme: .dark
        )

        // Both lay the email out in light colours; dark mode recolours it once loaded.
        for document in [light, dark] {
            XCTAssertTrue(document.contains("color-scheme: light"))
            XCTAssertTrue(document.contains("--plainpost-surface: #FFFFFF"))
        }
        XCTAssertTrue(light.contains("<meta name=\"plainpost-appearance\" content=\"light\">"))
        XCTAssertTrue(dark.contains("<meta name=\"plainpost-appearance\" content=\"dark\">"))
        XCTAssertTrue(dark.contains("Atkinson Hyperlegible"))
        XCTAssertTrue(dark.contains("font-family: Charter"))
    }

    @MainActor
    func testCoordinatorKeepsMessageContentWhenRemoteImagesAreEnabled() async throws {
        let receiver = try HTMLLoopbackReceiver()
        defer { receiver.stop() }
        await fulfillment(of: [receiver.ready], timeout: 5)
        let port = try XCTUnwrap(receiver.port, receiver.failureDescription)
        let imageURL = "http://127.0.0.1:\(port)/coordinator-policy-change"
        var contentHeight: CGFloat = 180
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(
                get: { contentHeight },
                set: { contentHeight = $0 }
            )
        )
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        defer { Self.dismantle(webView, coordinator: coordinator) }
        let html = "<main><h1>Property alert</h1><img src=\"\(imageURL)\"></main>"

        coordinator.load(html: html, allowsRemoteContent: false, in: webView)
        try await waitForText("Property alert", in: webView)
        try await waitForAttribute(
            "data-mail-remote-src",
            containing: imageURL,
            in: webView
        )

        let completion = HTMLPageCompletion()
        webView.navigationDelegate = completion
        coordinator.load(html: html, allowsRemoteContent: true, in: webView)
        await fulfillment(of: [completion.finished], timeout: 15)
        if let error = completion.error { throw error }
        try await waitForAttribute(
            "src",
            containing: imageURL,
            in: webView
        )
        try await waitForText("Property alert", in: webView)
        let imageComplete = try await webView.evaluateJavaScript("document.querySelector('img').complete && document.querySelector('img').naturalWidth > 0") as? Bool
        XCTAssertEqual(imageComplete, true)
        XCTAssertEqual(receiver.requests(for: "/coordinator-policy-change"), 1)
    }

    @MainActor
    func testCoordinatorAppliesDarkReaderDefaultsInWebKit() async throws {
        var contentHeight: CGFloat = 180
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(
                get: { contentHeight },
                set: { contentHeight = $0 }
            )
        )
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)

        coordinator.load(
            html: "<h1>Reader heading</h1><p>Reader body</p>",
            allowsRemoteContent: false,
            colorScheme: .dark,
            in: webView
        )
        try await waitForText("Reader body", in: webView)

        let background = try await webView.evaluateJavaScript(
            "getComputedStyle(document.body).backgroundColor"
        ) as? String
        let foreground = try await webView.evaluateJavaScript(
            "getComputedStyle(document.body).color"
        ) as? String
        let headingFont = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('h1')).fontFamily"
        ) as? String

        XCTAssertLessThan(try Self.brightness(XCTUnwrap(background)), 60, "dark mode darkens the reader's white page")
        XCTAssertGreaterThan(try Self.brightness(XCTUnwrap(foreground)), 150, "and lightens its text")
        XCTAssertTrue(headingFont?.contains("Charter") == true)
    }

    /// An email that colours itself through a stylesheet (a white box, grey text) is
    /// recoloured as a whole: the box goes dark and its text stays readable on it.
    @MainActor
    func testDarkModeRecoloursAStylesheetStyledEmailReadably() async throws {
        var contentHeight: CGFloat = 180
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { contentHeight }, set: { contentHeight = $0 })
        )
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        coordinator.load(
            html: """
            <html><head><style>.box{background:#ffffff}.greeting{color:#666666}</style></head>
            <body><table class="box"><tr><td><p class="greeting">Hello Oleh</p></td></tr></table></body></html>
            """,
            allowsRemoteContent: false,
            colorScheme: .dark,
            in: webView
        )
        try await waitForText("Hello Oleh", in: webView)
        try await Task.sleep(for: .milliseconds(200))
        let box = try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.box')).backgroundColor") as? String
        let text = try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.greeting')).color") as? String
        let boxBrightness = try Self.brightness(XCTUnwrap(box))
        XCTAssertLessThan(boxBrightness, 60, "the white box goes dark")
        XCTAssertGreaterThan(try Self.brightness(XCTUnwrap(text)) - boxBrightness, 65, "its text stays readable on it")
        Self.dismantle(webView, coordinator: coordinator)
    }

    /// A fixed-width email wider than the reader is scaled down to fit it, nothing cut off,
    /// and its reported height is the scaled one.
    @MainActor
    func testAWideEmailIsScaledToFitTheReader() async throws {
        var contentHeight: CGFloat = 120
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { contentHeight }, set: { contentHeight = $0 })
        )
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        coordinator.load(
            html: "<table width=\"600\"><tr><td style=\"height:600px\">Wide newsletter</td></tr></table>",
            allowsRemoteContent: false,
            colorScheme: .light,
            in: webView
        )
        try await waitForText("Wide newsletter", in: webView)
        try await Task.sleep(for: .milliseconds(300))
        let zoom = try await webView.evaluateJavaScript("parseFloat(document.body.style.zoom) || 1") as? Double
        let fitted = try await webView.evaluateJavaScript(
            "document.querySelector('table').getBoundingClientRect().right <= window.innerWidth + 1"
        ) as? Bool
        XCTAssertLessThan(try XCTUnwrap(zoom), 1)
        XCTAssertEqual(fitted, true)
        XCTAssertLessThan(contentHeight, 600, "the reported height is the scaled email's")
        Self.dismantle(webView, coordinator: coordinator)
    }

    /// Perceived brightness (0–255) of a computed `rgb(...)`/`rgba(...)` colour.
    private static func brightness(_ color: String) throws -> Double {
        let numbers = color.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 3 else { throw NSError(domain: "color", code: 0) }
        return (numbers[0] * 299 + numbers[1] * 587 + numbers[2] * 114) / 1000
    }

    @MainActor
    func testCoordinatorDiscardsPreparedDocumentAfterSelectionChanges() async throws {
        var contentHeight: CGFloat = 180
        let coordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(
                get: { contentHeight },
                set: { contentHeight = $0 }
            )
        )
        let webView = HTMLMessageView.makeWebView(coordinator: coordinator)
        let largeFirstMessage = String(repeating: "<p>Old selection</p>", count: 20_000)

        coordinator.load(html: largeFirstMessage, allowsRemoteContent: false, in: webView)
        coordinator.load(html: "<p>Newest selection</p>", allowsRemoteContent: false, in: webView)

        try await waitForText("Newest selection", in: webView)
        let bodyText = try await webView.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), "Newest selection")
    }

    @MainActor
    func testHTMLReadersShareAPrivateWebKitSessionAcrossSelections() {
        var firstHeight: CGFloat = 180
        var secondHeight: CGFloat = 180
        let firstCoordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { firstHeight }, set: { firstHeight = $0 })
        )
        let secondCoordinator = HTMLMessageView.Coordinator(
            contentHeight: Binding(get: { secondHeight }, set: { secondHeight = $0 })
        )

        let firstWebView = HTMLMessageView.makeWebView(coordinator: firstCoordinator)
        let secondWebView = HTMLMessageView.makeWebView(coordinator: secondCoordinator)

        XCTAssertTrue(firstWebView.configuration.websiteDataStore === secondWebView.configuration.websiteDataStore)
        XCTAssertTrue(firstWebView.configuration.websiteDataStore === HTMLMessageView.sharedWebsiteDataStore)
    }

#if os(macOS)
    @MainActor
    func testMacHTMLViewRoutesWheelEventsToTheReaderScrollView() throws {
        let readerScrollView = TrackingScrollView()
        let container = NSView(frame: .zero)
        readerScrollView.documentView = container

        let webView = ReaderHTMLWebView(frame: .zero, configuration: WKWebViewConfiguration())
        container.addSubview(webView)

        XCTAssertTrue(ReaderHTMLWebView.readerScrollView(containing: webView) === readerScrollView)

        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -30,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        webView.scrollWheel(with: event)

        XCTAssertTrue(readerScrollView.receivedWheelEvent)
    }
#endif

    @MainActor
    private func waitForText(_ expected: String, in webView: WKWebView) async throws {
        for _ in 0..<100 {
            let bodyText = try? await webView.evaluateJavaScript("document.body?.innerText || ''") as? String
            if bodyText?.contains(expected) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for rendered HTML text: \(expected)")
    }

    @MainActor
    private func waitForAttribute(
        _ attribute: String,
        containing expected: String,
        in webView: WKWebView
    ) async throws {
        for _ in 0..<100 {
            let value = try? await webView.evaluateJavaScript(
                "document.querySelector('img')?.getAttribute('\(attribute)') || ''"
            ) as? String
            if value?.contains(expected) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(attribute) containing: \(expected)")
    }
}

@MainActor
private final class RecordingHTMLWebView: WKWebView {
    var documents: [String] = []

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        documents.append(string)
        return nil
    }
}

@MainActor
private final class GatedHTMLPreparation {
    struct Input {
        let html: String
        let allowsRemoteContent: Bool
        let colorScheme: ColorScheme
    }
    private let gate = AsyncStream<Void>.makeStream()
    private(set) var inputs: [Input] = []
    private(set) var maximumActive = 0
    private var active = 0

    func start(html: String, allowsRemoteContent: Bool, colorScheme: ColorScheme) -> Task<String, Never> {
        inputs.append(Input(html: html, allowsRemoteContent: allowsRemoteContent, colorScheme: colorScheme))
        active += 1
        maximumActive = max(maximumActive, active)
        let first = inputs.count == 1
        let stream = gate.stream
        return Task.detached { [self] in
            if first {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            let document = HTMLMessageDocument.document(
                html: html, allowsRemoteContent: allowsRemoteContent, colorScheme: colorScheme
            )
            await finished()
            return document
        }
    }

    func releaseFirst() {
        gate.continuation.yield(())
        gate.continuation.finish()
    }

    private func finished() { active -= 1 }
}

@MainActor
private final class HTMLLifetimeReferences {
    weak var coordinator: HTMLMessageView.Coordinator?
    weak var webView: WKWebView?
}


@MainActor
private final class HTMLPageCompletion: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Owned HTML page navigation completed")
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }
}

// All socket state is confined to this owned queue; observable counters are
// protected by the lock. The only bind endpoint is explicitly IPv4 loopback.
private final class HTMLLoopbackReceiver: @unchecked Sendable {
    let ready = XCTestExpectation(description: "Owned IPv4 loopback receiver ready")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PlainpostUITests.HTMLLoopbackReceiver")
    private let lock = NSLock()
    private var requestCounts: [String: Int] = [:]
    private var listenerFailure: NWError?
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready.fulfill()
            case let .failed(error):
                self.lock.lock()
                self.listenerFailure = error
                self.lock.unlock()
                self.ready.fulfill()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            let request = HTMLLoopbackRequest(connection: connection, receiver: self)
            connection.start(queue: self.queue)
            request.receive()
        }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }

    var failureDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return listenerFailure.map { "Owned receiver prerequisite failure: \($0)" } ?? "Owned receiver has no ready port"
    }

    func requests(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path, default: 0]
    }

    fileprivate func record(path: String) {
        lock.lock()
        requestCounts[path, default: 0] += 1
        lock.unlock()
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class HTMLLoopbackRequest: @unchecked Sendable {
    private let connection: NWConnection
    private weak var receiver: HTMLLoopbackReceiver?
    private var bytes = Data()

    init(connection: NWConnection, receiver: HTMLLoopbackReceiver) {
        self.connection = connection
        self.receiver = receiver
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 16_384 else { connection.cancel(); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { receive() }
                return
            }
            let parts = header.split(separator: " ", maxSplits: 2)
            guard parts.count > 1, parts[0] == "GET" else { connection.cancel(); return }
            receiver?.record(path: String(parts[1]))
            let image = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(image.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            response.append(image)
            connection.send(content: response, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
    }
}
