import XCTest
@testable import PlainpostCore

final class AskMailAnswerTests: XCTestCase {
    private func source(_ id: String) -> MailKnowledgeSource {
        MailKnowledgeSource(id: "S1", messageID: MessageID(id), conversationKey: "thr_\(id)",
                            mailboxPath: "INBOX", subject: "Subject \(id)", sender: "Lena",
                            sentAt: Date(timeIntervalSince1970: 1_790_000_000), snippet: "Snippet")
    }

    private func row(_ id: String) -> AskMailMessageRow {
        AskMailMessageRow(messageID: MessageID(id), conversationKey: "thr_\(id)", mailboxPath: "INBOX",
                          sender: "GitHub", senderAddress: "noreply@github.com", subject: "CI failed",
                          snippet: "Run failed", sentAt: nil, isUnread: true, tag: nil)
    }

    func testAnswerRoundTripsThroughJSONWithEveryBlockKind() throws {
        let answer = AskMailAnswer(
            text: "Two things [1].",
            citations: [AskMailCitation(number: 1, source: source("m1"))],
            blocks: [
                .messages(AskMailMessageListBlock(
                    id: "automated", title: "Automated", icon: .tray, tint: .teal,
                    sections: [AskMailMessageSection(id: "notification", title: "Notifications", tint: .teal,
                                                     totalCount: 21, summary: "GitHub, Slack",
                                                     rows: [row("m2")], actionMessageIDs: [MessageID("m2")])],
                    bulkActions: [.markRead, .archive], rowAction: nil)),
                .card(AskMailCardBlock(
                    id: "card-m1", kind: .flight, title: "Swiss LX 318", badge: "Thu", hero: "ZRH → LHR",
                    subtitle: "Thursday 2 October · 07:40 – 08:25",
                    fields: [AskMailCardField(label: "Seat", value: "14A")], source: source("m1"),
                    calendarItem: AskMailCalendarItem(title: "LX 318", start: Date(timeIntervalSince1970: 0),
                                                      end: nil, location: "ZRH", notes: nil),
                    reminderItem: nil)),
                .quotes(AskMailQuoteBlock(id: "quotes", quotes: [
                    AskMailQuote(number: 1, source: source("m1"), excerpt: "We agreed on Friday.", highlight: "Friday")
                ])),
                .draft(AskMailDraftBlock(id: "draft", replyToMessageID: MessageID("m1"), recipientName: "Lena",
                                         recipientAddress: "lena@example.com", subject: "Re: Flat", body: "Hi Lena")),
                .options(AskMailOptionsBlock(id: "widen", title: "Try instead", options: [
                    AskMailOption(label: "Search all time", detail: nil, question: "offsite all time")
                ])),
            ],
            searched: [AskMailSearchToken(label: "Unread")],
            suggestions: ["Only this week"],
            insufficientEvidence: false
        )
        let data = try JSONEncoder().encode(answer)
        XCTAssertEqual(try JSONDecoder().decode(AskMailAnswer.self, from: data), answer)
    }

    func testReferencedMessageIDsCoverEveryBlock() {
        let answer = AskMailAnswer(
            text: "x", citations: [AskMailCitation(number: 1, source: source("cite"))],
            blocks: [
                .messages(AskMailMessageListBlock(id: "l", title: "L", icon: .tray, tint: .blue,
                    sections: [AskMailMessageSection(id: "s", title: "S", tint: .blue, totalCount: 2,
                        summary: "", rows: [row("row")], actionMessageIDs: [MessageID("row"), MessageID("hidden")])],
                    bulkActions: [], rowAction: .reply)),
                .draft(AskMailDraftBlock(id: "d", replyToMessageID: MessageID("draft"), recipientName: "",
                                         recipientAddress: "", subject: "", body: "")),
            ],
            searched: [], suggestions: [], insufficientEvidence: false)
        XCTAssertEqual(answer.referencedMessageIDs,
                       Set(["cite", "row", "hidden", "draft"].map { MessageID($0) }))
    }

    func testOptionFilterOverrideRoundTripsAndOldPayloadsDecode() throws {
        let option = AskMailOption(label: "Search all dates", detail: nil, question: "q", filterOverride: .dropDates)
        XCTAssertEqual(try JSONDecoder().decode(AskMailOption.self, from: JSONEncoder().encode(option)), option)
        let legacy = Data(#"{"label":"Search all dates","question":"q (any date)"}"#.utf8)
        let decoded = try JSONDecoder().decode(AskMailOption.self, from: legacy)
        XCTAssertNil(decoded.filterOverride)
        XCTAssertEqual(decoded.question, "q (any date)")
    }
}
