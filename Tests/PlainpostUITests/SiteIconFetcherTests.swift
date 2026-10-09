import AppKit
import XCTest
@testable import PlainpostUI

final class SiteIconFetcherTests: XCTestCase {
    func testFetcherUsesCookieFreeGETForDomainFavicon() async throws {
        let client = RecordingSiteIconHTTPClient(response: (makePNG(), 200, "image/png"))
        let fetcher = SiteIconFetcher(client: client)
        let domain = try XCTUnwrap(SiteIconDomain(sender: "alerts@example.com"))

        _ = try await fetcher.fetchPNG(for: domain)

        let request = await client.request()
        XCTAssertEqual(request.url, domain.faviconURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertGreaterThan(request.timeoutInterval, 0)
        XCTAssertLessThanOrEqual(request.timeoutInterval, SiteIconFetcher.timeout)
    }

    func testFetcherRejectsOversizedAndMalformedResponses() async throws {
        let domain = try XCTUnwrap(SiteIconDomain(sender: "alerts@example.com"))
        let tooLarge = SiteIconFetcher(client: RecordingSiteIconHTTPClient(response: (Data(repeating: 0, count: SiteIconFetcher.maximumResponseBytes + 1), 200, "image/png")))
        let malformed = SiteIconFetcher(client: RecordingSiteIconHTTPClient(response: (Data("not an image".utf8), 200, "image/png")))

        do { _ = try await tooLarge.fetchPNG(for: domain); XCTFail("Expected oversized response to fail") } catch { }
        do { _ = try await malformed.fetchPNG(for: domain); XCTFail("Expected malformed response to fail") } catch { }
    }

    func testFetcherFallsBackFromSenderSubdomainToMainSiteIcon() async throws {
        let icon = makePNG()
        let client = RoutingSiteIconHTTPClient(responses: [
            "https://www.paypal.com/favicon.ico": (icon, 200, "image/x-icon")
        ])
        let domain = try XCTUnwrap(SiteIconDomain(sender: "receipt@intl.paypal.com"))

        let png = try await SiteIconFetcher(client: client).fetchPNG(for: domain)
        XCTAssertFalse(png.isEmpty)
        let urls = await client.requestURLs()
        XCTAssertEqual(urls, [
            "https://intl.paypal.com/favicon.ico",
            "https://paypal.com/favicon.ico",
            "https://www.paypal.com/favicon.ico"
        ])
    }

    func testFetcherUsesSameHostRedirectedAppleTouchIcon() async throws {
        let icon = makePNG()
        let client = RoutingSiteIconHTTPClient(responses: [
            "https://flatfox.ch/apple-touch-icon.png": (Data(), 302, nil),
            "https://flatfox.ch/public/icon.png": (icon, 200, "image/png")
        ], redirects: ["https://flatfox.ch/apple-touch-icon.png": "/public/icon.png"])
        let domain = try XCTUnwrap(SiteIconDomain(sender: "news@flatfox.ch"))

        let png = try await SiteIconFetcher(client: client).fetchPNG(for: domain)
        XCTAssertFalse(png.isEmpty)
        let urls = await client.requestURLs()
        XCTAssertTrue(urls.contains("https://flatfox.ch/public/icon.png"))
    }

    func testFetcherNeverFollowsRedirectToAnotherHost() async throws {
        let client = RoutingSiteIconHTTPClient(responses: [
            "https://example.com/favicon.ico": (Data(), 302, nil)
        ], redirects: ["https://example.com/favicon.ico": "https://other.example/icon.png"])
        let domain = try XCTUnwrap(SiteIconDomain(sender: "news@example.com"))

        do {
            _ = try await SiteIconFetcher(client: client).fetchPNG(for: domain)
            XCTFail("Expected the cross-host redirect to be rejected")
        } catch { }
        let urls = await client.requestURLs()
        XCTAssertFalse(urls.contains("https://other.example/icon.png"))
    }

    func testFirstAttemptLeavesTimeForMainSiteFallback() async throws {
        let client = RoutingSiteIconHTTPClient(responses: [
            "https://www.galaxus.ch/favicon.ico": (makePNG(), 200, "image/x-icon")
        ])
        let domain = try XCTUnwrap(SiteIconDomain(sender: "news@notifications.galaxus.ch"))

        _ = try await SiteIconFetcher(client: client).fetchPNG(for: domain)
        let timeouts = await client.requestTimeouts()
        XCTAssertLessThanOrEqual(try XCTUnwrap(timeouts.first), 2.5)
    }
}

private actor RoutingSiteIconHTTPClient: SiteIconHTTPClient {
    private let responses: [String: (Data, Int, String?)]
    private let redirects: [String: String]
    private var urls: [String] = []
    private var timeouts: [TimeInterval] = []
    init(responses: [String: (Data, Int, String?)], redirects: [String: String] = [:]) {
        self.responses = responses
        self.redirects = redirects
    }
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int, mimeType: String?, redirectLocation: String?) {
        let url = request.url!.absoluteString
        urls.append(url)
        timeouts.append(request.timeoutInterval)
        let response = responses[url] ?? (Data(), 404, nil)
        return (response.0, response.1, response.2, redirects[url])
    }
    func requestURLs() -> [String] { urls }
    func requestTimeouts() -> [TimeInterval] { timeouts }
}

private actor RecordingSiteIconHTTPClient: SiteIconHTTPClient {
    private let response: (Data, Int, String?)
    private var captured: URLRequest?
    init(response: (Data, Int, String?)) { self.response = response }
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int, mimeType: String?, redirectLocation: String?) { captured = request; return (response.0, response.1, response.2, nil) }
    func request() -> URLRequest { captured! }
}

private func makePNG() -> Data {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
}
