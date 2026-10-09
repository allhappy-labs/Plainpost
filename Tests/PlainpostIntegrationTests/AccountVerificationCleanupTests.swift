import Foundation
import XCTest
@testable import PlainpostAccounts
@testable import PlainpostCore

final class AccountVerificationCleanupTests: XCTestCase {
    func testCleanupDeletesExactMessageNewerThanBaseline() async {
        let message = AccountVerificationMessage(
            accountEmail: EmailAddress("me@example.com"),
            identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let client = CleanupIMAPClient(
            uidResponses: [[8]],
            headers: [8: message.smtpData.components(separatedBy: "\r\n\r\n")[0]]
        )
        let cleanup = AccountVerificationCleanup(
            maximumAttempts: 6,
            retryDelay: .milliseconds(500),
            sleep: { _ in }
        )

        await cleanup.delete(message: message, newerThan: 7, using: client)

        XCTAssertEqual(client.requestedBaselines, [7])
        XCTAssertEqual(client.deletedUIDs, [8])
    }

    func testCleanupRetriesMissingDeliveryWithoutThrowing() async {
        let message = AccountVerificationMessage(accountEmail: EmailAddress("me@example.com"))
        let client = CleanupIMAPClient(
            uidResponses: [[], [9]],
            headers: [9: message.smtpData.components(separatedBy: "\r\n\r\n")[0]]
        )
        let sleeps = SleepRecorder()
        let cleanup = AccountVerificationCleanup(
            maximumAttempts: 2,
            retryDelay: .milliseconds(500),
            sleep: { duration in await sleeps.record(duration) }
        )

        await cleanup.delete(message: message, newerThan: 7, using: client)

        XCTAssertEqual(client.deletedUIDs, [9])
        let recordedDurations = await sleeps.durations
        XCTAssertEqual(recordedDurations, [.milliseconds(500)])
    }

    func testCleanupConsumesRemoteDeleteFailure() async {
        let message = AccountVerificationMessage(accountEmail: EmailAddress("me@example.com"))
        let client = CleanupIMAPClient(
            uidResponses: [[8]],
            headers: [8: message.smtpData.components(separatedBy: "\r\n\r\n")[0]],
            deleteFails: true
        )
        let cleanup = AccountVerificationCleanup(maximumAttempts: 1, sleep: { _ in })

        await cleanup.delete(message: message, newerThan: nil, using: client)

        XCTAssertEqual(client.deleteAttempts, [8])
    }

    func testCleanupConsumesLookupFetchAndTimeoutFailures() async {
        let message = AccountVerificationMessage(accountEmail: EmailAddress("me@example.com"))
        let lookupFailure = CleanupIMAPClient(uidResponses: [], headers: [:], lookupFails: true)
        let fetchFailure = CleanupIMAPClient(uidResponses: [[8]], headers: [:])
        let timeout = CleanupIMAPClient(uidResponses: [[], []], headers: [:])
        let cleanup = AccountVerificationCleanup(maximumAttempts: 2, sleep: { _ in })

        await cleanup.delete(message: message, newerThan: 7, using: lookupFailure)
        await cleanup.delete(message: message, newerThan: 7, using: fetchFailure)
        await cleanup.delete(message: message, newerThan: 7, using: timeout)

        XCTAssertTrue(lookupFailure.deletedUIDs.isEmpty)
        XCTAssertTrue(fetchFailure.deletedUIDs.isEmpty)
        XCTAssertTrue(timeout.deletedUIDs.isEmpty)
        XCTAssertEqual(timeout.requestedBaselines, [7, 7])
    }
}

private actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private enum CleanupClientFailure: Error {
    case lookup
    case missingHeader
    case delete
}

private final class CleanupIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private var uidResponses: [[Int]]
    let headers: [Int: String]
    let deleteFails: Bool
    let lookupFails: Bool
    private(set) var requestedBaselines: [Int?] = []
    private(set) var deleteAttempts: [Int] = []
    private(set) var deletedUIDs: [Int] = []

    init(
        uidResponses: [[Int]],
        headers: [Int: String],
        deleteFails: Bool = false,
        lookupFails: Bool = false
    ) {
        self.uidResponses = uidResponses
        self.headers = headers
        self.deleteFails = deleteFails
        self.lookupFails = lookupFails
    }

    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { [] }
    func selectMailbox(_ path: String) async throws -> String { "* 0 EXISTS" }
    func allMessageUIDs() async throws -> [Int] { uidResponses.first ?? [] }

    func messageUIDs(after uid: Int?) async throws -> [Int] {
        requestedBaselines.append(uid)
        if lookupFails { throw CleanupClientFailure.lookup }
        guard !uidResponses.isEmpty else { return [] }
        return uidResponses.removeFirst()
    }

    func fetchHeader(uid: Int) async throws -> String {
        guard let header = headers[uid] else { throw CleanupClientFailure.missingHeader }
        return header
    }

    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}

    func delete(uid: Int) async throws {
        deleteAttempts.append(uid)
        if deleteFails { throw CleanupClientFailure.delete }
        deletedUIDs.append(uid)
    }

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}
