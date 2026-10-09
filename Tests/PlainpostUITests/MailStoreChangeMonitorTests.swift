import XCTest
@testable import PlainpostDB
@testable import PlainpostUI

final class MailStoreChangeMonitorTests: XCTestCase {
    /// A private center: no other test's store signal can reach the monitor.
    private func post(_ scope: MailStoreChangeScope?, to center: NotificationCenter) {
        center.post(
            name: MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: scope.map { [MailStoreChangeSignal.scopeUserInfoKey: $0.rawValue] }
        )
    }

    /// Polls until `condition` holds or a deadline passes: the debounces
    /// are real sleeps, which a loaded machine can stretch far past them.
    @MainActor
    private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition did not become true") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testOperationChangeDoesNotInvalidateMailboxRevision() async throws {
        let center = NotificationCenter()
        let monitor = MailStoreChangeMonitor(notificationCenter: center, observeDistributedNotifications: false)

        post(.operations, to: center)
        // The operations debounce (500 ms) is the longest: once it fired, a
        // mailbox or account debounce (200 ms) would have fired too.
        try await waitUntil { monitor.operationRevision == 1 }

        XCTAssertEqual(monitor.mailboxRevision, 0)
        XCTAssertEqual(monitor.accountRevision, 0)
        XCTAssertEqual(monitor.operationRevision, 1)
    }

    @MainActor
    func testLegacyPayloadDefaultsToAllScopes() async throws {
        let center = NotificationCenter()
        let monitor = MailStoreChangeMonitor(notificationCenter: center, observeDistributedNotifications: false)

        post(nil, to: center)
        try await waitUntil {
            monitor.mailboxRevision == 1 && monitor.accountRevision == 1 && monitor.operationRevision == 1
        }

        XCTAssertEqual(monitor.mailboxRevision, 1)
        XCTAssertEqual(monitor.accountRevision, 1)
        XCTAssertEqual(monitor.operationRevision, 1)
    }
}
