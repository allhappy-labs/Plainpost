import AppKit
import SwiftUI
import XCTest
@testable import PlainpostUI

@MainActor
final class SiteIconDirectoryTests: XCTestCase {
    func testDebugAcceptanceUsesIsolatedCacheWithoutNetworkOrDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acceptance-site-icons-\(UUID().uuidString)", isDirectory: true)
        let client = CountingSiteIconHTTPClient(response: makePNG())
        let suite = "SiteIconDirectoryAcceptanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: SiteIconPreference.fetchEnabledKey)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let model = try SiteIconDirectoryModel.debugAcceptance(
            rootURL: root,
            client: client
        )
        model.resolveIfNeeded(sender: "sender@example.invalid")
        await model.waitForIdleForTesting()

        let requestCount = await client.count()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
        XCTAssertTrue(defaults.bool(forKey: SiteIconPreference.fetchEnabledKey))
    }

    func testDirectoryFetchesVisibleDomainOnceAndPublishesIcon() async throws {
        let client = CountingSiteIconHTTPClient(response: makePNG())
        let model = try await makeDirectory(client: client, enabled: true)

        model.resolveIfNeeded(sender: "one@example.com")
        model.resolveIfNeeded(sender: "two@example.com")
        await model.waitForIdleForTesting()

        let requestCount = await client.count()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNotNil(model.data(for: "three@example.com"))
    }

    func testDirectoryDoesNotFetchWhenDisabled() async throws {
        let client = CountingSiteIconHTTPClient(response: makePNG())
        let model = try await makeDirectory(client: client, enabled: false)

        model.resolveIfNeeded(sender: "one@example.com")
        await model.waitForIdleForTesting()

        let requestCount = await client.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testVisibleSenderAvatarUpdatesAfterIconFetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "SiteIconAvatarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: SiteIconPreference.fetchEnabledKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = try SiteIconDirectoryModel(
            cache: SiteIconCache(rootURL: root),
            fetcher: SiteIconFetcher(client: CountingSiteIconHTTPClient(response: makePNG())),
            defaults: defaults
        )
        let size = NSSize(width: 48, height: 48)
        let view = NSHostingView(rootView: MailSenderAvatar(sender: "news@example.com", size: 40)
            .mailSiteIconDirectory(model)
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        defer { window.close() }

        let before = try renderedPNG(of: view)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.data(for: "news@example.com"))
        defaults.set(true, forKey: SiteIconPreference.fetchEnabledKey)
        for _ in 0..<100 where model.data(for: "news@example.com") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.data(for: "news@example.com"))
        await Task.yield()

        XCTAssertNotEqual(try renderedPNG(of: view), before, "The visible avatar must redraw when the icon arrives")
    }
}

@MainActor
private func renderedPNG(of view: NSView) throws -> Data {
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
}

private actor CountingSiteIconHTTPClient: SiteIconHTTPClient {
    private let response: Data; private var requests = 0
    init(response: Data) { self.response = response }
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int, mimeType: String?, redirectLocation: String?) { requests += 1; return (response, 200, "image/png", nil) }
    func count() -> Int { requests }
}

@MainActor
private func makeDirectory(client: any SiteIconHTTPClient, enabled: Bool) async throws -> SiteIconDirectoryModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "SiteIconDirectoryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(enabled, forKey: SiteIconPreference.fetchEnabledKey)
    return try SiteIconDirectoryModel(cache: SiteIconCache(rootURL: root), fetcher: SiteIconFetcher(client: client), defaults: defaults)
}

private func makePNG() -> Data { NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])! }
