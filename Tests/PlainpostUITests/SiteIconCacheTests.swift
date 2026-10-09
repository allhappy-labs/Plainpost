import AppKit
import XCTest
@testable import PlainpostUI

final class SiteIconCacheTests: XCTestCase {
    func testSuccessExpiresAfterThirtyDays() async throws {
        let cache = try SiteIconCache(rootURL: temporaryDirectory())
        let domain = try XCTUnwrap(SiteIconDomain(sender: "alerts@example.com"))
        let now = Date(timeIntervalSince1970: 1_000)
        let png = makePNG()

        try await cache.storeSuccess(domain, pngData: png, now: now)

        let cached = try await cache.cachedIcon(for: domain, now: now)
        let expired = try await cache.cachedIcon(for: domain, now: now.addingTimeInterval(30 * 86_400 + 1))
        XCTAssertEqual(cached.pngData, png)
        XCTAssertNil(expired.pngData)
    }

    func testFailureIsNegativeCachedAndClearRemovesIt() async throws {
        let cache = try SiteIconCache(rootURL: temporaryDirectory())
        let domain = try XCTUnwrap(SiteIconDomain(sender: "alerts@example.com"))
        let now = Date(timeIntervalSince1970: 1_000)
        try await cache.storeFailure(domain, now: now)
        let failed = try await cache.cachedIcon(for: domain, now: now)
        XCTAssertTrue(failed.isNegativeCached)
        try await cache.clear()
        let cleared = try await cache.cachedIcon(for: domain, now: now)
        XCTAssertFalse(cleared.isNegativeCached)
    }

    func testOldFailureEntryIsRetriedAfterFetchPolicyChanges() async throws {
        let root = temporaryDirectory()
        let index = #"{"version":1,"entries":{"intl.paypal.com":{"outcome":"failure","expiresAt":900000000}}}"#
        try Data(index.utf8).write(to: root.appendingPathComponent("index.json"))
        let cache = try SiteIconCache(rootURL: root)
        let domain = try XCTUnwrap(SiteIconDomain(sender: "receipt@intl.paypal.com"))

        let result = try await cache.cachedIcon(for: domain, now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertFalse(result.isNegativeCached)
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePNG() -> Data {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
}
