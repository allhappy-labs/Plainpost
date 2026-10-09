import XCTest
import PlainpostOperations
@testable import PlainpostUI

final class OperationActivityPresentationTests: XCTestCase {
    private func row(state: PlainpostOperationState, active: Bool) -> OperationActivityRowModel {
        OperationActivityRowModel(
            id: "job_1", title: "Sorting mail", state: state, phase: "Classifying", detail: "Smart Inbox",
            providerID: "ollama", modelID: "qwen3:8b", accountEmail: "ada@example.com", resultDetail: nil,
            current: 1, total: 4, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 5),
            attempt: 2, maxAttempts: 3,
            terminalOccurrenceAt: active ? nil : Date(timeIntervalSince1970: 60)
        )
    }

    func testMetadataNamesTheAccountAndTimeButNoInternals() {
        let line = OperationActivityPresentation.metadata(row(state: .failed, active: false), now: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(line.contains("ada@example.com"))
        for banned in ["qwen3", "Ollama", "ollama", "Attempt", "job_1"] {
            XCTAssertFalse(line.contains(banned), banned)
        }
    }

    func testActiveRowsShowNoTimer() {
        let line = OperationActivityPresentation.metadata(row(state: .running, active: true), now: Date(timeIntervalSince1970: 125))
        XCTAssertFalse(line.contains("2m 5s"))
        XCTAssertFalse(line.contains("125s"))
    }

    func testFinishedRowsShowARelativeTimeComputedFromNow() {
        let ended = Date(timeIntervalSince1970: 60)
        let now = Date(timeIntervalSince1970: 120)
        let line = OperationActivityPresentation.metadata(row(state: .failed, active: false), now: now)
        let expected = RelativeDateTimeFormatter().localizedString(for: ended, relativeTo: now)
        XCTAssertTrue(line.contains(expected), "expected \"\(expected)\" in \"\(line)\"")

        // A different `now` must change the relative description. This fails if `metadata`
        // silently uses the system clock instead of the `now` it was given.
        let muchLater = now.addingTimeInterval(60 * 60 * 24 * 3)
        let laterLine = OperationActivityPresentation.metadata(row(state: .failed, active: false), now: muchLater)
        XCTAssertNotEqual(line, laterLine)
    }
}
