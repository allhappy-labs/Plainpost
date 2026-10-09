import Foundation
import PlainpostAccounts
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
import XCTest

/// The iPhone's direct route for a Sync Node account in fallback.
final class DeviceDirectMailDispatcherTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var failure: (any Error)?
        func append(_ call: String) { lock.withLock { stored.append(call) } }
        var values: [String] { lock.withLock { stored } }
    }

    /// A store with one Node account holding one mirrored message, in `mode`.
    private func makeStore(_ harness: NodeMailMirrorHarness, mode: NodeBackedMode) async throws -> MessageID {
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let bridge = DeviceNodeMailBridge(store: harness.store, broker: harness.broker(), window: { _ in nil })
        await bridge.start()
        for _ in 0..<500 where (try? harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID)) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await bridge.stop()
        if mode == .fallback {
            let source = try harness.store.mailSource(accountID: harness.accountID)
            _ = try harness.store.replaceMailSource(source.withMode(.fallback), expectedGeneration: source.generation)
        }
        return try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))
    }

    private func dispatcher(_ store: SQLiteMailStore, _ calls: Calls) -> DeviceDirectMailDispatcher {
        DeviceDirectMailDispatcher(
            store: store,
            perform: { action, messageID, folder in
                if let failure = calls.failure { throw failure }
                calls.append("\(action) \(messageID.rawValue) \(folder ?? "-")")
            },
            deliver: { draftID, hash in calls.append("send \(draftID.rawValue) \(hash)") }
        )
    }

    func testAFallbackAccountsChangeGoesToItsProvider() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let messageID = try await makeStore(harness, mode: .fallback)
        let calls = Calls()
        try await dispatcher(harness.store, calls).perform(.archive, messageID: messageID, archiveMailbox: "Archive")
        try await dispatcher(harness.store, calls).perform(.markRead, messageID: messageID, archiveMailbox: nil)
        XCTAssertEqual(calls.values, ["archive \(messageID.rawValue) Archive", "markRead \(messageID.rawValue) -"])
    }

    func testFlagAndMoveWaitForTheNodeAsOnTheMac() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let messageID = try await makeStore(harness, mode: .fallback)
        let calls = Calls()
        for kind in [MailIntentKind.flag, .unflag, .move] {
            do {
                try await dispatcher(harness.store, calls).perform(kind, messageID: messageID, archiveMailbox: "Receipts")
                XCTFail("\(kind) went directly")
            } catch let deferral as DirectMailDispatchDeferral {
                XCTAssertFalse(deferral.transient)
            }
        }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testAnAccountBackWithItsNodeDefers() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let messageID = try await makeStore(harness, mode: .node)
        let calls = Calls()
        do {
            try await dispatcher(harness.store, calls).perform(.markRead, messageID: messageID, archiveMailbox: nil)
            XCTFail("a Node-mode account's change went directly")
        } catch let deferral as DirectMailDispatchDeferral {
            XCTAssertEqual(deferral.reason, "This account's mail is handled by the Sync Node again.")
        }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testAProviderRefusalBeforeAnyEffectIsARefusalAndALockIsADeferral() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let messageID = try await makeStore(harness, mode: .fallback)
        let calls = Calls()
        calls.failure = MailAuthenticationError.rejected
        do {
            try await dispatcher(harness.store, calls).perform(.delete, messageID: messageID, archiveMailbox: nil)
            XCTFail("expected a refusal")
        } catch is DirectMailDispatchRefusal {}
        calls.failure = IMAPClientError.unreachableBeforeCommand
        do {
            try await dispatcher(harness.store, calls).perform(.delete, messageID: messageID, archiveMailbox: nil)
            XCTFail("expected a deferral")
        } catch let deferral as DirectMailDispatchDeferral {
            XCTAssertTrue(deferral.transient)
        }
    }

    func testADraftStaysOnThePhone() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        _ = try await makeStore(harness, mode: .fallback)
        let draft = Draft(
            id: DraftID("draft-1"), accountID: harness.accountID, from: EmailAddress("user@example.test"),
            to: [], cc: [], bcc: [], subject: "", bodyPlain: "", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil
        )
        do {
            try await dispatcher(harness.store, Calls()).saveDraft(draft)
            XCTFail("a draft went directly")
        } catch is DirectMailDispatchDeferral {}
        try await dispatcher(harness.store, Calls()).send(draft, approvedContentHash: "hash")
    }
}
