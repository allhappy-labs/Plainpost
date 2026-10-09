import Foundation
import XCTest
@testable import PlainpostUI

final class SiteIconPreferencesTests: XCTestCase {
    func testFetchDefaultsToEnabledAndCanBeDisabled() {
        let suiteName = "SiteIconPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SiteIconPreference.fetchEnabled(defaults: defaults))

        defaults.set(false, forKey: SiteIconPreference.fetchEnabledKey)

        XCTAssertFalse(SiteIconPreference.fetchEnabled(defaults: defaults))
    }

    func testDomainNormalizesAnEmailAddressAndBuildsFaviconURL() throws {
        let domain = try XCTUnwrap(SiteIconDomain(sender: "News <alerts@News.Example.com>"))

        XCTAssertEqual(domain.host, "news.example.com")
        XCTAssertEqual(domain.faviconURL.absoluteString, "https://news.example.com/favicon.ico")
    }

    func testDomainRejectsLocalAndIPAddressHosts() {
        XCTAssertNil(SiteIconDomain(sender: "alerts@localhost"))
        XCTAssertNil(SiteIconDomain(sender: "alerts@printer.local"))
        XCTAssertNil(SiteIconDomain(sender: "alerts@127.0.0.1"))
        XCTAssertNil(SiteIconDomain(sender: "alerts@[::1]"))
    }
}
