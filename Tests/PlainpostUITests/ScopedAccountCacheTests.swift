import XCTest
import PlainpostCore
import PlainpostDB
@testable import PlainpostUI

final class ScopedAccountCacheTests: XCTestCase {
    private let center = NotificationCenter()
    private let gmail = Account(id: AccountID("g"), displayName: "", email: EmailAddress("me@gmail.com"),
                                imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")

    private func post(_ scope: MailStoreChangeScope) {
        center.post(name: MailStoreChangeSignal.notificationName, object: nil,
                    userInfo: [MailStoreChangeSignal.scopeUserInfoKey: scope.rawValue])
    }

    func testReadsTheStoreOnceForEveryRow() {
        let cache = ScopedAccountCache(centers: [center])
        var reads = 0
        for _ in 0..<200 {
            XCTAssertEqual(cache.account(gmail.id) { reads += 1; return gmail }, gmail)
        }
        XCTAssertEqual(reads, 1, "a 200-row list reads the accounts table once, not per row")
    }

    func testAMissingAccountIsCachedToo() {
        let cache = ScopedAccountCache(centers: [center])
        var reads = 0
        _ = cache.account(gmail.id) { reads += 1; return nil }
        XCTAssertNil(cache.account(gmail.id) { reads += 1; return nil })
        XCTAssertEqual(reads, 1)
    }

    func testAnAccountChangeRereadsAndMailChangesDoNot() {
        let cache = ScopedAccountCache(centers: [center])
        var reads = 0
        _ = cache.account(gmail.id) { reads += 1; return gmail }
        post(.mailbox)
        post(.operations)
        _ = cache.account(gmail.id) { reads += 1; return gmail }
        XCTAssertEqual(reads, 1, "mail and operation changes keep the account")
        post(.accounts)
        _ = cache.account(gmail.id) { reads += 1; return gmail }
        post(.all)
        _ = cache.account(gmail.id) { reads += 1; return gmail }
        XCTAssertEqual(reads, 3, "each account change reads the account again")
    }

    func testAChangeDuringTheReadDiscardsItsAnswer() {
        let cache = ScopedAccountCache(centers: [center])
        _ = cache.account(gmail.id) {
            post(.accounts)
            return nil
        }
        var reads = 0
        XCTAssertEqual(cache.account(gmail.id) { reads += 1; return gmail }, gmail)
        XCTAssertEqual(reads, 1, "the stale nil wasn't kept")
    }

    func testAnotherAccountIDReadsAgain() {
        let cache = ScopedAccountCache(centers: [center])
        var reads = 0
        _ = cache.account(gmail.id) { reads += 1; return gmail }
        _ = cache.account(AccountID("other")) { reads += 1; return nil }
        XCTAssertEqual(reads, 2)
    }
}
