import XCTest
@testable import PlainpostCore

final class MailLabelsTests: XCTestCase {
    func testSmartInboxLabelRequiresDescriptionAndNormalizesTitle() throws {
        XCTAssertThrowsError(try MailLabelDefinition.validated(
            title: " Travel ",
            description: "",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .smartInboxDescriptionRequired)
        }

        let label = try MailLabelDefinition.validated(
            id: "label-travel",
            title: " Travel ",
            description: "Flights, hotels, and itinerary updates.",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )
        XCTAssertEqual(label.title, "Travel")
        XCTAssertEqual(label.normalizedTitle, "travel")
    }

    func testAccountScopeIncludesOnlyItsAccount() {
        XCTAssertTrue(MailLabelScope.allAccounts.includes(AccountID("a")))
        XCTAssertTrue(MailLabelScope.account(AccountID("a")).includes(AccountID("a")))
        XCTAssertFalse(MailLabelScope.account(AccountID("a")).includes(AccountID("b")))
    }

    func testTitleAndDescriptionLengthBoundariesAreInclusive() throws {
        let valid = try MailLabelDefinition.validated(
            title: String(repeating: "T", count: 64),
            description: String(repeating: "D", count: 280),
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )
        XCTAssertEqual(valid.title.count, 64)
        XCTAssertEqual(valid.description.count, 280)

        XCTAssertThrowsError(try MailLabelDefinition.validated(
            title: String(repeating: "T", count: 65),
            description: "Description",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .titleTooLong)
        }
        XCTAssertThrowsError(try MailLabelDefinition.validated(
            title: "Title",
            description: String(repeating: "D", count: 281),
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .descriptionTooLong)
        }
    }

    func testClassificationKeepsTriageAndLabelMatches() {
        let value = SmartInboxClassification(
            messageID: MessageID("m1"),
            category: .travel,
            priority: .high,
            requiresAction: true,
            confidence: 0.91,
            labelMatches: [.init(labelID: "label-travel", confidence: 0.88)]
        )
        XCTAssertEqual(value.priority, .high)
        XCTAssertTrue(value.requiresAction)
        XCTAssertEqual(value.labelMatches.map(\.labelID), ["label-travel"])
    }
}
