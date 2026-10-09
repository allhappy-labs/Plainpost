import XCTest
@testable import PlainpostUI

final class MobileComposeFieldTests: XCTestCase {
    func testReturnWalksToCcBccSubjectThenBody() {
        XCTAssertEqual(MobileComposeField.to.next(showsCcBcc: true), .cc)
        XCTAssertEqual(MobileComposeField.cc.next(showsCcBcc: true), .bcc)
        XCTAssertEqual(MobileComposeField.bcc.next(showsCcBcc: true), .subject)
        XCTAssertEqual(MobileComposeField.subject.next(showsCcBcc: true), .body)
        XCTAssertEqual(MobileComposeField.body.next(showsCcBcc: true), .body)
    }

    func testReturnSkipsCcAndBccWhileTheyAreCollapsed() {
        XCTAssertEqual(MobileComposeField.to.next(showsCcBcc: false), .subject)
        XCTAssertEqual(MobileComposeField.subject.next(showsCcBcc: false), .body)
    }
}
