import XCTest
@testable import PlainpostCore
@testable import PlainpostUI

final class AskMailListSelectionTests: XCTestCase {
    private func block() -> AskMailMessageListBlock {
        func section(_ id: String, _ ids: [String]) -> AskMailMessageSection {
            AskMailMessageSection(id: id, title: id, tint: .teal, totalCount: ids.count, summary: "", rows: [],
                                  actionMessageIDs: ids.map { MessageID($0) })
        }
        return AskMailMessageListBlock(id: "b", title: "B", icon: .tray, tint: .teal,
                                       sections: [section("n", ["a", "b", "c"]), section("l", ["d", "e"])],
                                       bulkActions: [.markRead], rowAction: nil)
    }

    func testDefaultsToAllSelectedAndTracksPartialSections() {
        var selection = AskMailListSelection(block: block())
        XCTAssertEqual(selection.totalSelected, 5)
        selection.toggleRow(MessageID("a"), in: "n")
        XCTAssertEqual(selection.sectionState("n"), .some)
        XCTAssertEqual(selection.selectedCount(in: "n"), 2)
        XCTAssertEqual(selection.totalSelected, 4)
        selection.toggleSection("n")          // some → none
        XCTAssertEqual(selection.sectionState("n"), .none)
        selection.toggleSection("n")          // none → all
        XCTAssertEqual(selection.sectionState("n"), .all)
        XCTAssertEqual(selection.selectedMessageIDs(in: "l"), [MessageID("d"), MessageID("e")])
    }

    func testToggleRowRoundTripReturnsToAll() {
        var selection = AskMailListSelection(block: block())
        XCTAssertEqual(selection.sectionState("n"), .all)
        selection.toggleRow(MessageID("a"), in: "n")
        XCTAssertEqual(selection.sectionState("n"), .some)
        selection.toggleRow(MessageID("a"), in: "n")
        XCTAssertEqual(selection.sectionState("n"), .all)
        XCTAssertEqual(selection.totalSelected, 5)
    }
}
