import XCTest
@testable import PlainpostCore

final class VerificationCodeDetectorTests: XCTestCase {
    private func code(subject: String = "", _ body: String) -> String? {
        VerificationCodeDetector.code(subject: subject, body: body)
    }

    func testCodeOnItsOwnLineAfterThePrompt() {
        let body = """
        Hey olhapi!

        A sign in attempt requires further verification because we did not recognize your device. \
        To complete the sign in, enter the verification code on the unrecognized device.

        Verification code: 482913

        If you did not attempt to sign in to your account, your password may be compromised.
        """
        XCTAssertEqual(code(subject: "[GitHub] Please verify your device", body), "482913")
    }

    func testCodeBeforeTheWordCodeInTheSubject() {
        XCTAssertEqual(code(subject: "123456 is your Instagram code", "Someone tried to log in."), "123456")
    }

    func testSplitCodeIsCopiedWithoutTheSeparator() {
        XCTAssertEqual(code("Your sign-in code is 381 027. It expires in 10 minutes."), "381027")
        XCTAssertEqual(code("Your sign-in code is 381-027."), "381027")
    }

    func testUppercaseLettersAndDigits() {
        XCTAssertEqual(code("Your one-time passcode is K7Q29X."), "K7Q29X")
    }

    func testUkrainianCode() {
        XCTAssertEqual(code("Ваш код підтвердження: 5821. Нікому його не повідомляйте."), "5821")
    }

    func testNumberWithoutACodePromptIsIgnored() {
        XCTAssertNil(code(subject: "Your order has shipped", "Order 553201 left our warehouse on Monday."))
    }

    func testPromoCodeIsNotAVerificationCode() {
        XCTAssertNil(code("Use discount code SUMMER26 at checkout to save 20%."))
    }

    func testOrderNumberNearTheWordCodeIsIgnored() {
        XCTAssertNil(code("Show this code at pickup for order #553201."))
    }

    func testYearsDatesPricesAndPhoneNumbersAreIgnored() {
        let body = """
        Your verification code is 739201.
        Requested on 12.03.2026 at 9:40, © 2026.
        Didn't ask for a code? Call 0800 123 456 or check the $4500.00 payment.
        """
        XCTAssertEqual(code(body), "739201")
    }

    func testTwoDifferentCandidatesShowNothing() {
        XCTAssertNil(code("Your code is 111222. Your backup code is 333444."))
    }

    func testTheSameCodeInSubjectAndBodyCountsOnce() {
        XCTAssertEqual(code(subject: "Your code: 904417", "Enter 904417 to continue. Your code expires soon."), "904417")
    }

    func testPlainMailHasNoCode() {
        XCTAssertNil(code(subject: "Lunch on Friday?", "Are you free at 12:30? The new place on 5th street."))
    }
}
