import XCTest
@testable import PlainpostUI

/// Read-only mail disables the reply items, not the whole menu. Draft with AI and Translate
/// moved to the ✦ pane, so the menu holds only Reply, Reply All and Forward.
final class MobileReplyMenuTests: XCTestCase {
    func testReadOnlyMailDisablesReplyItems() {
        XCTAssertFalse(MobileReplyMenu(allowsMutations: false).allowsReplies)
    }

    func testWritableMailOffersEveryItem() {
        XCTAssertTrue(MobileReplyMenu(allowsMutations: true).allowsReplies)
    }
}
