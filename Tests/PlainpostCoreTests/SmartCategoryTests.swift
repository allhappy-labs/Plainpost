import XCTest
@testable import PlainpostCore

final class SmartCategoryTests: XCTestCase {
    func testListUnsubscribeClassifiesNewsletter() {
        let input = CategoryInput(
            from: "newsletter@example.com",
            subject: "Weekly update",
            headers: ["List-Unsubscribe": "<mailto:unsubscribe@example.com>"],
            bodyPreview: "Latest news"
        )

        let result = SmartCategoryClassifier().classify(input)

        XCTAssertEqual(result.category, .newsletter)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testAutoSubmittedClassifiesNotification() {
        let input = CategoryInput(
            from: "builds@example.com",
            subject: "Build complete",
            headers: ["Auto-Submitted": "auto-generated"],
            bodyPreview: "The build finished."
        )

        let result = SmartCategoryClassifier().classify(input)

        XCTAssertEqual(result.category, .notification)
    }

    func testHumanLikeSenderClassifiesPersonal() {
        let input = CategoryInput(
            from: "alice@example.com",
            subject: "Lunch",
            headers: [:],
            bodyPreview: "Can we meet tomorrow?"
        )

        let result = SmartCategoryClassifier().classify(input)

        XCTAssertEqual(result.category, .personal)
    }
}
