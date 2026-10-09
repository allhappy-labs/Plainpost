import XCTest
@testable import PlainpostOperations
@testable import PlainpostUI

final class SmartInboxSettingsPageTests: XCTestCase {
    func testCutoffFooterOnlyForNewMailOnly() {
        let since = DateComponents(calendar: .current, year: 2026, month: 10, day: 2).date!
        XCTAssertEqual(SmartInboxPageText.cutoffFooter(.newMailOnly(since: since)),
                       "Mail from before \(since.formatted(.dateTime.month(.abbreviated).day())) isn't sorted.")
        XCTAssertNil(SmartInboxPageText.cutoffFooter(.allMail))
        XCTAssertNil(SmartInboxPageText.cutoffFooter(.off))
    }

    func testStatusLine() {
        XCTAssertEqual(SmartInboxPageText.status(mode: .allMail, processed: 120, total: 400, lowPowerPaused: false), "Sorting 120 of 400")
        XCTAssertEqual(SmartInboxPageText.status(mode: .allMail, processed: nil, total: nil, lowPowerPaused: true), "Paused in Low Power Mode")
        XCTAssertEqual(SmartInboxPageText.status(mode: .newMailOnly(since: Date()), processed: nil, total: nil, lowPowerPaused: true), "Paused in Low Power Mode")
        XCTAssertNil(SmartInboxPageText.status(mode: .allMail, processed: nil, total: nil, lowPowerPaused: false))
    }

    /// With sorting Off, Low Power Mode has nothing to pause, so the page says nothing about it.
    func testStatusOmitsLowPowerPauseWhenSortingIsOff() {
        XCTAssertNil(SmartInboxPageText.status(mode: .off, processed: nil, total: nil, lowPowerPaused: true))
    }

    func testPageHidesOllamaAndProviderInternals() throws {
        let source = try pageSource()
        for banned in ["Ollama", "Locality", "modelSummary", "Indexed messages", "Enabled\")"] {
            XCTAssertFalse(source.contains(banned), banned)
        }
    }

    /// Before iOS 26 the page must show only the gating text: no Smart Inbox controls, AI
    /// Model row, or Translation picker. `translationSection` must live inside the
    /// `aiRequiresNewerIOS` `else` branch, not after it.
    func testTranslationSectionHiddenBeforeIOS26Gate() throws {
        let source = try pageSource()
        guard let ifRange = source.range(of: "if aiRequiresNewerIOS {"),
              let elseRange = source.range(of: "} else {", range: ifRange.upperBound..<source.endIndex) else {
            XCTFail("Could not find the aiRequiresNewerIOS gate in SmartInboxSettingsPage.swift")
            return
        }
        let gatedBranch = source[ifRange.upperBound..<elseRange.lowerBound]
        XCTAssertFalse(gatedBranch.contains("translationSection"), "translationSection must not render before the iOS 26 gate")

        guard let bodyCloseRange = source.range(of: "\n        }\n    }", range: elseRange.upperBound..<source.endIndex) else {
            XCTFail("Could not find the end of the else branch in SmartInboxSettingsPage.swift")
            return
        }
        let elseBranch = source[elseRange.upperBound..<bodyCloseRange.lowerBound]
        XCTAssertTrue(elseBranch.contains("translationSection"), "translationSection must render once AI is available")
    }

    private func pageSource() throws -> String {
        try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/SmartInboxSettingsPageTests.swift",
            with: "Sources/PlainpostUI/Settings/SmartInboxSettingsPage.swift"))
    }
}
