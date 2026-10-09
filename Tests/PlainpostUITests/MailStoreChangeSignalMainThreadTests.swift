import Combine
import PlainpostDB
import XCTest
@testable import PlainpostUI

/// Ledger Task 8: store changes posted from a background thread reach SwiftUI on the main thread.
final class MailStoreChangeSignalMainThreadTests: XCTestCase {
    func testABackgroundStoreChangeArrivesOnTheMainThread() {
        let center = NotificationCenter()
        let arrived = expectation(description: "the change arrives")
        var onMain = false
        var scope: MailStoreChangeScope?
        let subscription = MailStoreChangeSignal.mainThreadPublisher(center: center).sink {
            onMain = Thread.isMainThread
            scope = $0
            arrived.fulfill()
        }
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            center.post(
                name: MailStoreChangeSignal.notificationName, object: nil,
                userInfo: [MailStoreChangeSignal.scopeUserInfoKey: MailStoreChangeScope.accounts.rawValue]
            )
        }
        wait(for: [arrived], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(onMain)
        XCTAssertEqual(scope, .accounts)
    }
}
