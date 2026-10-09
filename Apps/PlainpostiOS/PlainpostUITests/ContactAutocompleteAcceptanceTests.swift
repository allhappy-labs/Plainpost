import XCTest

@MainActor
final class ContactAutocompleteAcceptanceTests: XCTestCase {
    func testRecipientAutocompleteStaysInlineAndInsertsSelectedAddress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_DEBUG_NODE_SINGLE_ACCOUNT"] = "1"
        app.launchEnvironment["PLAINPOST_CONTACT_AUTOCOMPLETE_UI_ACCEPTANCE"] = "1"
        app.launch()

        if isPhone {
            XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 60), app.debugDescription)
        } else {
            XCTAssertTrue(app.staticTexts["Analytical engine notes"].waitForExistence(timeout: 60), app.debugDescription)
        }

        let compose = app.buttons["mailbox.toolbar.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), app.debugDescription)
        compose.tap()

        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10), app.debugDescription)
        to.tap()
        to.typeText("autocomplete")

        let suggestion = app.buttons["Autocomplete Contact, autocomplete@example.test"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.sheets.count, 0, "Recipient completion should stay inline, not open a sheet")
        XCTAssertGreaterThanOrEqual(suggestion.frame.minY, to.frame.maxY - 4)
        XCTAssertLessThan(suggestion.frame.minY, to.frame.maxY + 220,
                          "The contact suggestion should remain near the To field")
        XCTAssertLessThan(suggestion.frame.height, 90,
                          "A suggestion row should stay compact instead of filling the screen")
        XCTAssertTrue(suggestion.isHittable, app.debugDescription)

        suggestion.tap()

        if isPhone {
            XCTAssertTrue(app.buttons["compose.token.to.autocomplete@example.test"].waitForExistence(timeout: 5),
                          "the chosen contact becomes a To token")
        } else {
            XCTAssertEqual(to.value as? String, "autocomplete@example.test, ")
        }
        XCTAssertFalse(suggestion.exists, "Selecting a contact should dismiss the completion list")
    }
}
