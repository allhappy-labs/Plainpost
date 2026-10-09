import XCTest
@testable import PlainpostUI

final class SummaryReplyActionTests: XCTestCase {
    func testReplyActionPrefersSafeReplyToAddress() {
        let thread = makeThread(
            sender: "sender@example.com",
            replyTo: "replies@example.com"
        )

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg-1", thread: thread),
            "replies@example.com"
        )
    }

    func testReplyActionFallsBackToValidFromWhenReplyToIsMalformed() {
        let thread = makeThread(
            sender: "sender@example.com",
            replyTo: "not-an-address"
        )

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg-1", thread: thread),
            "sender@example.com"
        )
    }

    func testReplyActionAllowsAutomatedLookingAddress() {
        let thread = makeThread(sender: "notifications@post.ch", replyTo: nil)

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg-1", thread: thread),
            "notifications@post.ch"
        )
    }

    func testAutomatedLookingAddressIsReplyableButMarkedAdvisory() {
        let thread = makeThread(sender: "notifications@post.ch", replyTo: nil)

        XCTAssertTrue(
            SourceVerifiedReplyTarget.isLikelyAutomated(selectedMessageID: "msg-1", thread: thread)
        )
    }

    func testReplyActionFallsBackToFromWhenReplyToIsMissing() {
        let thread = makeThread(sender: "sender@example.com", replyTo: nil)

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg-1", thread: thread),
            "sender@example.com"
        )
    }

    func testReplyActionUsesOnlyTheSelectedEmailSender() {
        let thread = ThreadDetailModel(
            subject: "Project update",
            participants: ["alice@example.com", "bob@example.com"],
            summaryStatus: "Ready",
            actionItems: ["Delete this thread"],
            availableActions: ["Reply", "Delete"],
            messages: [
                ThreadMessageModel(id: "msg_alice", sender: "alice@example.com", body: .plainText("Hello")),
                ThreadMessageModel(id: "msg_bob", sender: "bob@example.com", body: .plainText("Follow up"))
            ]
        )

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg_alice", thread: thread),
            "alice@example.com"
        )
    }

    func testAutomatedSendersRemainReplyableButNotificationsDoNot() {
        let automated = ThreadDetailModel(
            subject: "Receipt",
            participants: ["no-reply@example.com"],
            summaryStatus: "Ready",
            actionItems: ["Archive receipt"],
            availableActions: ["Archive", "Delete"],
            messages: [
                ThreadMessageModel(id: "msg_automated", sender: "no-reply@example.com", body: .plainText("Receipt"))
            ]
        )
        let notification = ThreadDetailModel(
            subject: "Build complete",
            participants: ["person@example.com"],
            summaryStatus: "Ready",
            actionItems: ["Delete notification"],
            availableActions: ["Delete"],
            messages: [
                ThreadMessageModel(id: "msg_notification", sender: "person@example.com", body: .plainText("Done"))
            ],
            categoryLabel: "Notifications"
        )

        XCTAssertEqual(
            SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg_automated", thread: automated),
            "no-reply@example.com"
        )
        XCTAssertNil(SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg_notification", thread: notification))
    }

    func testReplyActionRejectsMessageWithoutUsableReplyAddress() {
        let thread = makeThread(sender: "not-an-address", replyTo: nil)

        XCTAssertNil(SourceVerifiedReplyTarget.recipient(selectedMessageID: "msg-1", thread: thread))
    }

    private func makeThread(sender: String, replyTo: String?) -> ThreadDetailModel {
        ThreadDetailModel(
            subject: "Project update",
            participants: [sender],
            summaryStatus: "Ready",
            actionItems: [],
            availableActions: ["Reply"],
            messages: [
                ThreadMessageModel(
                    id: "msg-1",
                    sender: sender,
                    replyTo: replyTo,
                    body: .plainText("Hello")
                )
            ]
        )
    }
}
