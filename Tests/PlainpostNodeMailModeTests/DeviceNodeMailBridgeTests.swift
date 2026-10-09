import Foundation
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
import PlainpostNodeTransport
import XCTest

/// The iPhone's Sync Node mail: the bridge mirrors Node accounts into the
/// device's database and sends their changes to the Node.
final class DeviceNodeMailBridgeTests: XCTestCase {
    private final class LockedWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int?
        init(_ value: Int?) { stored = value }
        var value: Int? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func bridge(_ harness: NodeMailMirrorHarness, window: Int? = nil) -> DeviceNodeMailBridge {
        DeviceNodeMailBridge(store: harness.store, broker: harness.broker(), window: { _ in window })
    }

    private func waitUntil(_ condition: () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    func testStartMirrorsTheNodeAccountsIntoTheStore() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setListedAccounts([FakeNodeMailServer.accountA])
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let bridge = bridge(harness)
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        let states = await bridge.accountStates()
        XCTAssertEqual(states, [harness.accountID: .ready])
        await bridge.stop()
    }

    func testTheWindowLimitsWhatTheBridgeMirrors() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for index in 0..<5 {
            harness.server.addMessage(nodeID: "n\(index)", rfcMessageID: "<n\(index)@example.test>",
                                      memberships: [("INBOX", 7, UInt32(5 - index), [])],
                                      receivedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index * 60)))
        }
        let bridge = bridge(harness, window: 2)
        await bridge.start()
        try await waitUntil { try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete == true }
        XCTAssertEqual(harness.store.messages.count, 2)
        await bridge.stop()
    }

    func testCompleteHistoryReopensTheMirrorBeyondTheWindow() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for index in 0..<5 {
            harness.server.addMessage(nodeID: "n\(index)", rfcMessageID: "<n\(index)@example.test>",
                                      memberships: [("INBOX", 7, UInt32(5 - index), [])],
                                      receivedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index * 60)))
        }
        let window = LockedWindow(2)
        let bridge = DeviceNodeMailBridge(store: harness.store, broker: harness.broker(), window: { _ in window.value })
        await bridge.start()
        try await waitUntil { try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete == true }
        XCTAssertEqual(harness.store.messages.count, 2)
        window.value = nil
        try await bridge.downloadCompleteHistory(for: harness.accountID)
        try await waitUntil { harness.store.messages.count == 5 }
        await bridge.stop()
    }

    /// The Plainpost Account path's accounts, known only to the Node, join the device's
    /// catalog and are mirrored like the attached one.
    func testStartAddsTheNodesAccountsToTheDeviceAndMirrorsThem() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setListedAccounts([FakeNodeMailServer.accountA, FakeNodeMailServer.accountB])
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 9, 1, [])],
                                  logical: FakeNodeMailServer.accountB)
        let bridge = bridge(harness)
        await bridge.start()
        let added = AccountID("acc_user1_example_test")
        let source = try harness.store.mailSource(accountID: added)
        XCTAssertEqual(source.kind, .nodeBacked)
        XCTAssertEqual(source.logicalMailboxID, try harness.key(FakeNodeMailServer.accountB))
        XCTAssertEqual(Set(harness.store.accounts.map(\.id)), [harness.accountID, added], "the attached account stays as it is")
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "b1", accountID: added) != nil }
        XCTAssertEqual(Set(try harness.store.mailboxes(limit: 10, accountID: added).map(\.path)), ["INBOX"],
                       "folders come from the mirrored mail's folders, never the catalog's opaque handles")
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "b1", accountID: added) != nil }
        await bridge.stop()

        // Every launch adds the catalog again; nothing is added twice.
        let again = self.bridge(harness)
        await again.start()
        XCTAssertEqual(harness.store.accounts.count, 2)
        await again.stop()
    }

    /// An account the Node stops listing stays on the device, marked, until the user
    /// removes it: nothing waiting on it goes silently.
    func testAnAccountTheNodeStopsListingIsMarkedAndKept() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setListedAccounts([FakeNodeMailServer.accountA, FakeNodeMailServer.accountB])
        let bridge = bridge(harness)
        await bridge.start()
        let added = AccountID("acc_user1_example_test")
        let listed = await bridge.accountStates()
        XCTAssertNotEqual(listed[added], .noLongerOnSyncNode)

        harness.server.setListedAccounts([FakeNodeMailServer.accountA])
        await bridge.wake()
        let states = await bridge.accountStates()
        XCTAssertEqual(states[added], .noLongerOnSyncNode)
        XCTAssertNotEqual(states[harness.accountID], .noLongerOnSyncNode)
        XCTAssertTrue(harness.store.accounts.contains { $0.id == added }, "the account stays until the user removes it")
        await bridge.stop()
    }

    func testFolderRowsMadeFromCatalogHandlesGoAway() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setListedAccounts([FakeNodeMailServer.accountA])
        try harness.store.cacheMailboxes([Mailbox(id: MailboxID("mbx_\(harness.accountID.rawValue)_node_opaque-handle"),
                                                  accountID: harness.accountID, name: "Receipts", path: "opaque-handle",
                                                  specialUse: nil)])
        let bridge = bridge(harness)
        await bridge.start()
        XCTAssertFalse(try harness.store.mailboxes(limit: 20, accountID: harness.accountID).contains { $0.path == "opaque-handle" })
        await bridge.stop()
    }

    func testTheMirrorRunsAgainAfterTheAppComesBack() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        let bridge = bridge(harness)
        await bridge.start()
        await bridge.stop()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        await bridge.stop()
    }

    func testArchiveGoesToTheNode() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let bridge = bridge(harness)
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))
        let outcome = try await bridge.perform(.archive, messageID: messageID)
        XCTAssertNotEqual(outcome, .failed(MailIntentRouter.refusedMessage))
        XCTAssertNotEqual(outcome, .waitingForNode)
        XCTAssertEqual(harness.server.count("POST /v1/mutations"), 1)
        await bridge.stop()
    }

    func testAChangeMadeWhileTheNodeIsAwayWaitsAndGoesWhenItIsBack() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let bridge = bridge(harness)
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))

        harness.server.setHealthy(false)
        let outcome = try await bridge.perform(.markRead, messageID: messageID)
        XCTAssertEqual(outcome, .waitingForNode)
        XCTAssertEqual(harness.server.count("POST /v1/mutations"), 0, "nothing left while the Node was away")

        harness.server.setHealthy(true)
        await bridge.wake()
        XCTAssertEqual(harness.server.count("POST /v1/mutations"), 1, "the waiting change went once the Node answered")
        await bridge.stop()
    }

    private static let quickReachability = NodeReachabilityPolicy(
        unhealthyWindow: .milliseconds(150), healthyWindow: .milliseconds(150),
        probeInterval: .milliseconds(30), probeTimeout: .milliseconds(500),
        flapMemory: .seconds(5), maximumHealthyWindow: .milliseconds(150), settleInterval: .seconds(5)
    )

    private func fallbackBridge(
        _ harness: NodeMailMirrorHarness, direct: RecordingDirectMailDispatcher, signedIn: Bool
    ) -> DeviceNodeMailBridge {
        DeviceNodeMailBridge(
            store: harness.store, broker: harness.broker(), window: { _ in nil },
            direct: direct, mayFallBack: { _ in signedIn }, reachability: Self.quickReachability
        )
    }

    /// With the account's sign-in on the phone, a Node that stays away hands the account to
    /// the phone: its changes go to the provider until the Node is back.
    func testASignedInAccountFallsBackWhileTheNodeIsAwayAndReturnsWithIt() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let direct = RecordingDirectMailDispatcher()
        let bridge = fallbackBridge(harness, direct: direct, signedIn: true)
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))

        harness.server.setHealthy(false)
        try await waitUntil { try harness.store.mailSource(accountID: harness.accountID).mode == .fallback }
        let outcome = try await bridge.perform(.markRead, messageID: messageID)
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(direct.performedActions.map(\.kind), [.markRead])
        XCTAssertEqual(harness.server.count("POST /v1/mutations"), 0)

        harness.server.setHealthy(true)
        try await waitUntil { try harness.store.mailSource(accountID: harness.accountID).mode == .node }
        await bridge.stop()
    }

    /// Without its sign-in on the phone the account stays with its Node: a change waits.
    func testAnAccountWithoutItsSignInStaysWithItsNode() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let direct = RecordingDirectMailDispatcher()
        let bridge = fallbackBridge(harness, direct: direct, signedIn: false)
        await bridge.start()
        try await waitUntil { try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID) != nil }
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))

        harness.server.setHealthy(false)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try harness.store.mailSource(accountID: harness.accountID).mode, .node)
        let outcome = try await bridge.perform(.markRead, messageID: messageID)
        XCTAssertEqual(outcome, .waitingForNode)
        XCTAssertTrue(direct.performedActions.isEmpty)
        await bridge.stop()
    }

    func testAnUnreachableNodeMarksItsAccounts() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setHealthy(false)
        let bridge = bridge(harness)
        await bridge.start()
        for _ in 0..<500 where await bridge.accountStates()[harness.accountID] != .unreachable {
            try await Task.sleep(for: .milliseconds(10))
        }
        let states = await bridge.accountStates()
        XCTAssertEqual(states, [harness.accountID: .unreachable])
        await bridge.stop()
    }
}
