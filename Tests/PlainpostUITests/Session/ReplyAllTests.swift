import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class ReplyAllTests: XCTestCase {
    private func message(from: String, replyTo: String? = nil, to: [String], cc: [String]) -> ThreadMessageModel {
        ThreadMessageModel(
            id: "m1", sender: from, senderDisplayName: nil, replyTo: replyTo, dateLabel: "Sep 26",
            body: .plainText("Hi"), sourceThreadID: nil, rfcMessageID: "<m1@x>", inReplyTo: nil,
            references: [], attachments: [], to: to, cc: cc
        )
    }

    func testReplyAllExcludesOwnAddressesAndDeduplicates() {
        let m = message(from: "maria@x.example", to: ["me@mine.example", "tom@x.example"], cc: ["MARIA@x.example", "ann@x.example", "me@mine.example"])
        let result = ComposeCoordinator.replyAllRecipients(message: m, ownAddresses: ["me@mine.example"])
        XCTAssertEqual(result.to, "maria@x.example")
        XCTAssertEqual(result.cc, ["tom@x.example", "ann@x.example"])
    }

    func testReplyAllHonoursReplyTo() {
        let m = message(from: "noreply@list.example", replyTo: "team@list.example", to: ["me@mine.example"], cc: [])
        let result = ComposeCoordinator.replyAllRecipients(message: m, ownAddresses: ["me@mine.example"])
        XCTAssertEqual(result.to, "team@list.example")
        XCTAssertEqual(result.cc, [])
    }

    func testPrepareReplyAllFillsCc() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        let context = ComposerReplyContext(
            sourceThreadID: nil, sourceMessageID: MessageID("m1"), rfcMessageID: "<m1@x>", references: [],
            recipient: "maria@x.example", subject: "Plan", senderName: "Maria", dateLabel: "Sep 26",
            quotedBody: "Hi", cc: ["tom@x.example", "ann@x.example"]
        )
        composer.prepareReplyAll(context: context)
        XCTAssertEqual(composer.to, "maria@x.example")
        XCTAssertEqual(composer.cc, "tom@x.example, ann@x.example")
        XCTAssertEqual(composer.subject, "Re: Plan")
    }

    func testStoredReplyContextWithoutCcStillDecodes() throws {
        let json = #"{"sourceMessageID":"m1","references":[],"recipient":"a@x","subject":"s","senderName":"n","dateLabel":"d","quotedBody":"q"}"#
        let context = try JSONDecoder().decode(ComposerReplyContext.self, from: Data(json.utf8))
        XCTAssertEqual(context.cc, [])
    }
}
