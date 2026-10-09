import XCTest
@testable import PlainpostAI
@testable import PlainpostCore

private struct CannedStructuredProvider: AIProvider {
    let id = "canned"; let displayName = "Canned"; let chatModelID = "canned-1"
    let capabilities = AICapabilities(supportsChat: true, supportsEmbeddings: false, supportsJSONMode: true,
                                      supportsStreaming: false, maxContextTokens: 4096, runsLocally: true)
    /// Nil fails every request, as a provider that isn't ready does.
    let json: String?
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse { throw AIProviderError.unavailable }
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        guard let json else { throw AIProviderError.unavailable }
        return AIStructuredGenerationResponse(json: Data(json.utf8), modelID: chatModelID, localOnly: true)
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}

final class AskMailCardExtractorTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Zurich")!; return c
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T08:00:00Z")! // Wednesday
    private let message = MessageSummary(id: MessageID("swiss"), threadID: nil, from: EmailAddress("booking@swiss.com"),
                                         fromDisplayName: "Swiss", subject: "Your booking LX 318 is confirmed",
                                         preview: "Zurich → London", body: "LX 318 Thu 2 Oct 07:40", smartCategory: .travel)

    func testFlightCardWithCalendarItemAndBadge() async throws {
        let json = #"{"relevant":true,"kind":"flight","title":"Swiss LX 318","hero":"ZRH → LHR","subtitle":"Thursday 2 October · 07:40 – 08:25","fields":[{"label":"Seat","value":"14A"},{"label":"","value":"x"}],"startISO":"2026-10-02T07:40","location":"Zurich Airport"}"#
        let card = await AskMailCardExtractor(provider: CannedStructuredProvider(json: json), now: now, calendar: calendar)
            .card(for: message)
        let unwrapped = try XCTUnwrap(card)
        XCTAssertEqual(unwrapped.kind, .flight)
        XCTAssertEqual(unwrapped.hero, "ZRH → LHR")
        XCTAssertEqual(unwrapped.badge, "Fri") // 2 October 2026 is a Friday
        XCTAssertEqual(unwrapped.fields, [AskMailCardField(label: "Seat", value: "14A")])
        XCTAssertEqual(unwrapped.calendarItem?.location, "Zurich Airport")
        XCTAssertEqual(unwrapped.calendarItem?.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7, minute: 40)))
        XCTAssertEqual(unwrapped.source.messageID, message.id)
    }

    func testInvoiceGetsReminderAndDueBadge() async throws {
        let json = #"{"relevant":true,"kind":"invoice","title":"Marco Rossi","hero":"CHF 2,400.00","subtitle":"September sprint","fields":[],"startISO":"2026-10-02"}"#
        let card = try await XCTUnwrapAsync { await AskMailCardExtractor(provider: CannedStructuredProvider(json: json), now: now, calendar: calendar).card(for: message) }
        XCTAssertEqual(card.badge, "Due Fri")
        XCTAssertEqual(card.reminderItem?.title, "Pay Marco Rossi")
        XCTAssertNil(card.calendarItem)
    }

    func testPastDateGetsNoBadge() async throws {
        let json = #"{"relevant":true,"kind":"flight","title":"Swiss LX 318","hero":"ZRH → LHR","subtitle":"","fields":[],"startISO":"2026-09-27T07:40"}"#
        let card = try await XCTUnwrapAsync { await AskMailCardExtractor(provider: CannedStructuredProvider(json: json), now: now, calendar: calendar).card(for: message) }
        XCTAssertNil(card.badge)
        XCTAssertNotNil(card.calendarItem)
    }

    func testMalformedCardIsDropped() async {
        for json in [#"{"relevant":false,"kind":"other","title":"x","hero":"y","subtitle":"","fields":[]}"#,
                     #"{"relevant":true,"kind":"flight","title":"","hero":"","subtitle":"","fields":[]}"#,
                     #"not json"#] {
            let card = await AskMailCardExtractor(provider: CannedStructuredProvider(json: json), now: now, calendar: calendar).card(for: message)
            XCTAssertNil(card, json)
        }
    }

    /// "Nothing actionable" is an answer; a provider failure throws, so callers can try again.
    func testDetectCardTellsNothingFoundFromAFailure() async throws {
        let irrelevant = #"{"relevant":false,"kind":"other","title":"x","hero":"y","subtitle":"","fields":[]}"#
        let nothing = try await AskMailCardExtractor(provider: CannedStructuredProvider(json: irrelevant), now: now, calendar: calendar)
            .detectCard(for: message)
        XCTAssertNil(nothing)

        let failing = AskMailCardExtractor(provider: CannedStructuredProvider(json: nil), now: now, calendar: calendar)
        do {
            _ = try await failing.detectCard(for: message)
            XCTFail("a provider failure throws")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
        let swallowed = await failing.card(for: message)
        XCTAssertNil(swallowed)
    }

    func testUnparseableDateKeepsCardWithoutCalendarItem() async throws {
        let json = #"{"relevant":true,"kind":"event","title":"Viewing","hero":"Saturday","subtitle":"","fields":[],"startISO":"next Saturday"}"#
        let card = try await XCTUnwrapAsync { await AskMailCardExtractor(provider: CannedStructuredProvider(json: json), now: now, calendar: calendar).card(for: message) }
        XCTAssertNil(card.calendarItem)
        XCTAssertNil(card.badge)
    }
}

private func XCTUnwrapAsync<T>(_ value: () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v, file: file, line: line)
}
