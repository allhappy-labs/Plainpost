import XCTest

/// Settings pages must never print internal identifiers. This scans the settings sources for the
/// patterns that leaked before the redesign.
final class SettingsNoRawIdentifierTests: XCTestCase {
    func testSettingsSourcesDoNotRenderRawIdentifiers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/PlainpostUI/PlainpostSettingsViews.swift",
            "Sources/PlainpostUI/PlainpostSharedViews.swift",
            "Sources/PlainpostUI/AccountSecuritySettingsView.swift",
            "Sources/PlainpostUI/SyncNodeEnrollmentViews.swift",
            "Sources/PlainpostUI/SyncNodeSettingsView.swift",
            "Sources/PlainpostUI/SyncNodeSettingsPage.swift",
            "Sources/PlainpostUI/CalendarSettingsView.swift",
        ] + (try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/PlainpostUI/Settings").path)
            .map { "Sources/PlainpostUI/Settings/\($0)" })
        let banned = [
            "\"Account ID\"", "Current Sync Node", "String(describing: model.operationPhase)",
            "nodeID.rawValue", "\"Attempt ", "\"Endpoint\"", "\"Locality\"",
            "Runtime health", "Rotating local log", "100% of local mail", "Enforced protections",
        ]
        // `modelID` is legitimate data plumbing (copying an `OperationActivityRowModel`), so it is
        // banned only on lines that render text.
        let bannedInRenderedText = ["modelID"]
        let renderingCalls = ["Text(", "LabeledContent(", "Label(", "SystemSettingsValueRow("]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for token in banned {
                XCTAssertFalse(source.contains(token), "\(file) contains \(token)")
            }
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where renderingCalls.contains(where: { line.contains($0) }) {
                for token in bannedInRenderedText {
                    XCTAssertFalse(line.contains(token), "\(file):\(index + 1) renders \(token)")
                }
            }
        }
    }
}
