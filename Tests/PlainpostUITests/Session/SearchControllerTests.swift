import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class SearchControllerTests: XCTestCase {
    private func make(canAskMail: Bool = true, asked: ((String) -> Void)? = nil)
        -> (SearchController, MailboxController) {
        let mailbox = MailboxController(
            destination: .smartInbox, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .smartInboxOverview)
        )
        let controller = SearchController(
            search: .designTips(),
            rebuild: MailSearchIndexRebuildController(
                indexState: { .unavailable }, rebuild: {}, allowsRebuild: true, announce: { _ in }
            ),
            mailbox: mailbox,
            accounts: { [] }, askMail: { asked?($0) }, canAskMail: { canAskMail }, afterOpen: { _ in }
        )
        return (controller, mailbox)
    }

    func testPresentResetsQueryAndBumpsGeneration() {
        let (controller, _) = make()
        controller.present(query: "  parcel ")
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.search.query, "parcel")
        XCTAssertEqual(controller.presentationGeneration, 1)
    }

    func testOpenKeepsQueryWhenNotClosing() {
        let (controller, mailbox) = make()
        controller.present(query: "parcel")
        controller.open(MessageID("m9"), closesSearch: false)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.search.query, "parcel")
        XCTAssertEqual(mailbox.selectedMessageID, "m9")
        XCTAssertEqual(mailbox.selectedDestination, .allInboxes)
    }

    func testOpenClosesSearchOnTheMac() {
        let (controller, _) = make()
        controller.present(query: "parcel")
        controller.open(MessageID("m9"), closesSearch: true)
        XCTAssertFalse(controller.isPresented)
    }

    func testAskMailActionHiddenWhenUnavailable() {
        XCTAssertNil(make(canAskMail: false).0.askMailAction)
    }

    func testAskMailPassesTheQuery() {
        var asked: String?
        let (controller, _) = make(asked: { asked = $0 })
        controller.present(query: "invoices")
        controller.askMailAction?()
        XCTAssertEqual(asked, "invoices")
        XCTAssertFalse(controller.isPresented)
    }
}
