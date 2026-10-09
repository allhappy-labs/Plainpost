import XCTest
@testable import PlainpostUI

final class MobileRecipientTokenListTests: XCTestCase {
    func testTypedTextSplitsIntoTokensAndFragment() {
        let list = MobileRecipientTokenList(text: "a@x.example, b@y.example, ma")
        XCTAssertEqual(list.tokens, ["a@x.example", "b@y.example"])
        XCTAssertEqual(list.fragment, "ma")
        XCTAssertEqual(list.text, "a@x.example, b@y.example, ma")
    }

    func testPrefilledTextIsAllTokens() {
        let list = MobileRecipientTokenList.prefilled("alice@example.com, bob@example.com")
        XCTAssertEqual(list.tokens, ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(list.fragment, "")
        XCTAssertEqual(list.text, "alice@example.com, bob@example.com, ")
    }

    func testPrefilledTextSplitsOnSemicolonsAndLineBreaksToo() {
        let list = MobileRecipientTokenList.prefilled("alice@example.com; bob@example.com,carol@example.com\ndan@example.com;")
        XCTAssertEqual(list.tokens, ["alice@example.com", "bob@example.com", "carol@example.com", "dan@example.com"])
        XCTAssertEqual(list.fragment, "")
    }

    func testCommaSemicolonOrSpaceAfterAnAddressCommits() {
        var list = MobileRecipientTokenList(text: "")
        list.setFragment("bob@x.example,")
        list.setFragment("carol@y.example;")
        list.setFragment("dan@z.example ")
        XCTAssertEqual(list.tokens, ["bob@x.example", "carol@y.example", "dan@z.example"])
        list.setFragment("Maria ")
        XCTAssertEqual(list.fragment, "Maria ", "a space inside a name keeps typing")
    }

    func testDuplicatesMergeIgnoringCase() {
        var list = MobileRecipientTokenList(text: "")
        list.commit("Tom@Okafor.example")
        list.commit("tom@okafor.example")
        XCTAssertEqual(list.tokens, ["Tom@Okafor.example"])
        XCTAssertEqual(list.excluded, ["tom@okafor.example"])
    }

    func testRemoveDropsTheToken() {
        var list = MobileRecipientTokenList.prefilled("a@x.example, b@y.example")
        list.remove("A@X.example")
        XCTAssertEqual(list.tokens, ["b@y.example"])
    }

    func testATapSelectsATokenWithoutRemovingIt() {
        var list = MobileRecipientTokenList.prefilled("a@x.example, b@y.example")
        list.toggleSelection("a@x.example")
        XCTAssertEqual(list.tokens, ["a@x.example", "b@y.example"], "one tap never removes a recipient")
        XCTAssertEqual(list.selected, "a@x.example")
        list.toggleSelection("b@y.example")
        XCTAssertEqual(list.selected, "b@y.example", "a tap on another token moves the selection")
        list.toggleSelection("b@y.example")
        XCTAssertNil(list.selected, "a second tap clears it")
    }

    func testRemovingTheSelectedTokenIsTheSecondStep() {
        var list = MobileRecipientTokenList.prefilled("a@x.example, b@y.example")
        list.removeSelected()
        XCTAssertEqual(list.tokens, ["a@x.example", "b@y.example"], "nothing selected, nothing removed")
        list.toggleSelection("a@x.example")
        list.removeSelected()
        XCTAssertEqual(list.tokens, ["b@y.example"])
        XCTAssertNil(list.selected)
    }

    func testTypingClearsTheSelection() {
        var list = MobileRecipientTokenList.prefilled("a@x.example")
        list.toggleSelection("a@x.example")
        list.setFragment("c")
        XCTAssertNil(list.selected)
    }
}
