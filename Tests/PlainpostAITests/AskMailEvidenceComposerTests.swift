import XCTest
@testable import PlainpostAI
@testable import PlainpostCore

final class AskMailEvidenceComposerTests: XCTestCase {
    private func source(_ id: String, _ snippet: String) -> MailKnowledgeSource {
        MailKnowledgeSource(id: id, messageID: MessageID("m-\(id)"), conversationKey: "c", mailboxPath: "INBOX",
                            subject: "Flat deposit", sender: "Lena Brandt", sentAt: nil, snippet: snippet)
    }

    private func result(_ text: String, _ sources: [MailKnowledgeSource]) -> MailboxQuestionAnswer {
        MailboxQuestionAnswer(answer: text, sources: sources, insufficientEvidence: false, providerName: "p",
                              modelID: "m", localOnly: true, retrievalMode: .lexical)
    }

    func testRenumbersCitationsInOrderOfAppearanceAndDropsUncited() throws {
        let s1 = source("S1", "Unrelated.")
        let s2 = source("S2", "The deposit is two months' rent. Keys on Friday.")
        let s3 = source("S3", "They accept SwissCaution instead of cash.")
        let answer = AskMailEvidenceComposer.answer(
            from: result("Deposit is two months [S2]. SwissCaution works [S3]. Again [S2].", [s1, s2, s3]),
            question: "What did we agree about the deposit?", searched: [])
        XCTAssertEqual(answer.text, "Deposit is two months [1]. SwissCaution works [2]. Again [1].")
        XCTAssertEqual(answer.citations.map(\.number), [1, 2])
        XCTAssertEqual(answer.citations.map(\.source.messageID), [s2.messageID, s3.messageID])
        guard case .quotes(let quotes) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(quotes.quotes.map(\.number), [1, 2])
        XCTAssertEqual(quotes.quotes[0].highlight, "The deposit is two months' rent.")
    }

    func testQuoteHighlightMustComeFromSource() throws {
        let s1 = source("S1", "Nothing in common here.")
        let answer = AskMailEvidenceComposer.answer(from: result("Answer [S1].", [s1]),
                                                    question: "What about the deposit?", searched: [])
        guard case .quotes(let quotes) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(quotes.quotes[0].highlight, "")
        XCTAssertTrue(quotes.quotes.allSatisfy { $0.highlight.isEmpty || $0.excerpt.contains($0.highlight) })
    }

    func testLongExcerptIsTrimmedAtWordBoundary() throws {
        let long = String(repeating: "deposit words here ", count: 40)
        let answer = AskMailEvidenceComposer.answer(from: result("A [S1].", [source("S1", long)]),
                                                    question: "deposit", searched: [])
        guard case .quotes(let quotes) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertLessThanOrEqual(quotes.quotes[0].excerpt.count, 321)
        XCTAssertTrue(quotes.quotes[0].excerpt.hasSuffix("…"))
    }

    func testUnknownCitationMarkersAreRemoved() throws {
        let s1 = source("S1", "Found it here.")
        let answer = AskMailEvidenceComposer.answer(from: result("Yes [S99]. Also [S1].", [s1]),
                                                    question: "where is it?", searched: [])
        XCTAssertEqual(answer.text, "Yes. Also [1].")
        XCTAssertEqual(answer.citations.map(\.number), [1])
        guard case .quotes(let quotes) = try XCTUnwrap(answer.blocks.first) else { return XCTFail() }
        XCTAssertEqual(quotes.quotes.map(\.number), [1])
    }
}
