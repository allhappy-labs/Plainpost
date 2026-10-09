import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostOperations

final class PlainpostLocalAIArtifactPayloadTests: XCTestCase {
    func testLegacyPayloadWithoutAskMailAnswerDecodes() throws {
        let legacy = #"{"text":"Hi","items":[],"localOnly":true,"sources":[]}"#
        let payload = try JSONDecoder().decode(PlainpostLocalAIArtifactPayload.self, from: Data(legacy.utf8))
        XCTAssertNil(payload.askMailAnswer)
    }

    func testAskMailAnswerRoundTrips() throws {
        let answer = AskMailAnswer(text: "Found **2** messages.", searched: [.init(label: "Unread")])
        let payload = PlainpostLocalAIArtifactPayload(text: answer.text, askMailAnswer: answer)
        let decoded = try JSONDecoder().decode(PlainpostLocalAIArtifactPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.askMailAnswer, answer)
    }

    func testAIOperationInputCarriesAskMailFilterOverride() throws {
        let input = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox", providerID: "local",
            question: "unread today", askMailFilterOverride: .dropDates)
        let decoded = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.askMailFilterOverride, .dropDates)
        let legacy = #"{"operation":"answerMailboxQuestion","recordID":"mailbox","providerID":"local","conversation":[]}"#
        XCTAssertNil(try JSONDecoder().decode(PlainpostAIOperationInput.self, from: Data(legacy.utf8)).askMailFilterOverride)
    }

    func testAIOperationInputCarriesDraftTone() throws {
        let input = PlainpostAIOperationInput(
            operation: .draftReply, recordID: "thread-1", providerID: "local",
            question: "Ask for an extension", draftTone: "formal")
        let decoded = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.draftTone, "formal")
        XCTAssertEqual(decoded.question, "Ask for an extension")
        let legacy = #"{"operation":"draftReply","recordID":"thread-1","providerID":"local","conversation":[]}"#
        XCTAssertNil(try JSONDecoder().decode(PlainpostAIOperationInput.self, from: Data(legacy.utf8)).draftTone)
    }

    func testUndecodableAskMailAnswerKeepsTheRestOfThePayload() throws {
        let newer = #"{"text":"Hi","localOnly":true,"sources":[],"askMailAnswer":{"text":"Hi","citations":[],"blocks":[{"timeline":{"_0":{"id":"t"}}}],"searched":[],"suggestions":[],"insufficientEvidence":false}}"#
        let payload = try JSONDecoder().decode(PlainpostLocalAIArtifactPayload.self, from: Data(newer.utf8))
        XCTAssertNil(payload.askMailAnswer)
        XCTAssertEqual(payload.text, "Hi")
    }
}
