import AppKit
import SwiftUI
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport
@testable import PlainpostUI

@MainActor
final class ConversationDetectedActionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }()
    private let britishEnglish = Locale(identifier: "en_GB")

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9))! }
    private var deadline: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 9))! }

    // MARK: Mapping

    func testCalendarItemBecomesAnAddChipWithItsTitleAndDate() {
        let actions = ConversationDetectedAction.actions(
            from: detectedCard(start: deadline), now: now, calendar: calendar, locale: britishEnglish
        )
        XCTAssertEqual(actions.map(\.kind), [.calendar])
        XCTAssertEqual(actions.first?.title, "📅 Add “Tax deadline” 31 Mar")
    }

    func testReminderItemBecomesRemindMe() {
        let actions = ConversationDetectedAction.actions(
            from: detectedCard(start: nil, reminderDue: deadline), now: now, calendar: calendar, locale: britishEnglish
        )
        XCTAssertEqual(actions.map(\.kind), [.reminder])
        XCTAssertEqual(actions.first?.title, "⏰ Remind me")
    }

    func testNothingFoundOffersNoChips() {
        XCTAssertTrue(ConversationDetectedAction.actions(from: nil, now: now, calendar: calendar, locale: britishEnglish).isEmpty)
    }

    /// Review Focus 5: an item dated before today offers no chip.
    func testPastDatedItemsOfferNoChip() {
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 31, hour: 9))!
        XCTAssertTrue(ConversationDetectedAction.actions(
            from: detectedCard(start: lastYear, reminderDue: lastYear), now: now, calendar: calendar, locale: britishEnglish
        ).isEmpty)
        let earlierToday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 7))!
        XCTAssertEqual(ConversationDetectedAction.actions(
            from: detectedCard(start: earlierToday), now: now, calendar: calendar, locale: britishEnglish
        ).map(\.kind), [.calendar], "today still counts")
    }

    // MARK: Model

    func testDetectionRunsOncePerNewestMessageAndContent() async {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)))
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))

        model.paneDidAppear()
        await model.ensureDetection()?.value
        model.paneDidDisappear()
        model.paneDidAppear()
        await model.ensureDetection()?.value

        XCTAssertEqual(detector.requests, [MessageID("m2")])
        XCTAssertEqual(model.detectedActions.map(\.kind), [.calendar])
        XCTAssertFalse(model.isDetectingActions)

        model.setConversation(planContext(selected: "m2", extra: [paneMessage("m3", thread: "thread-plan")]))
        await model.ensureDetection()?.value
        XCTAssertEqual(detector.requests, [MessageID("m2"), MessageID("m3")], "a new reply is detected again")
    }

    /// Nothing found while AI was unavailable isn't final: another provider detects again.
    func testAnotherProviderDetectsAgain() async {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)))
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))
        model.paneDidAppear()
        await model.ensureDetection()?.value

        model.assistantDidReconfigure()
        await model.ensureDetection()?.value

        XCTAssertEqual(detector.requests, [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(model.detectedActions.map(\.kind), [.calendar])
    }

    /// Final review I1: AI that isn't ready yet isn't "nothing found". The failure isn't cached,
    /// so opening the pane again detects again and the chip appears.
    func testAFailedDetectionIsNotCachedAndReopeningDetectsAgain() async {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)), failures: 1)
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))
        model.paneDidAppear()
        await model.ensureDetection()?.value
        XCTAssertTrue(model.detectedActions.isEmpty)
        XCTAssertFalse(model.isDetectingActions)

        model.paneDidDisappear()
        model.paneDidAppear()
        await model.ensureDetection()?.value

        XCTAssertEqual(detector.requests, [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(model.detectedActions.map(\.kind), [.calendar])
    }

    /// Final review I1: "Check again" detects the newest message again after a failure.
    func testCheckAgainDetectsAgainAfterAFailure() async {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)), failures: 1)
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))
        model.paneDidAppear()
        await model.ensureDetection()?.value
        XCTAssertTrue(model.detectedActions.isEmpty)

        model.checkAgain()
        await model.ensureDetection()?.value

        XCTAssertEqual(detector.requests, [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(model.detectedActions.map(\.kind), [.calendar])
    }

    /// A genuine "nothing found" is an answer: it's cached, and only "Check again" asks again.
    func testNothingFoundIsCachedUntilCheckAgain() async {
        let detector = RecordingDetector(card: nil)
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))
        model.paneDidAppear()
        await model.ensureDetection()?.value
        model.paneDidDisappear()
        model.paneDidAppear()
        await model.ensureDetection()?.value
        XCTAssertEqual(detector.requests, [MessageID("m2")])

        model.checkAgain()
        await model.ensureDetection()?.value

        XCTAssertEqual(detector.requests, [MessageID("m2"), MessageID("m2")])
        XCTAssertTrue(model.detectedActions.isEmpty)
    }

    func testChipsStayHiddenWhileDetectingAndALateResultIsDropped() async {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)), gated: true)
        let model = makeDetectingModel(detector: detector)
        model.setConversation(planContext(selected: "m2"))
        let pending = model.ensureDetection()
        XCTAssertTrue(model.isDetectingActions)
        XCTAssertTrue(model.detectedActions.isEmpty)
        await detector.waitUntilAsked()

        model.setConversation(dinnerContext())
        detector.release()
        await pending?.value

        XCTAssertTrue(model.detectedActions.isEmpty)
        XCTAssertFalse(model.isDetectingActions)
    }

    func testPerformUsesAskMailsCalendarWritingAndWording() async throws {
        let model = makeDetectingModel(detector: NoConversationActionDetector())
        let actions = ConversationDetectedAction.actions(
            from: detectedCard(start: Date().addingTimeInterval(86_400), reminderDue: Date().addingTimeInterval(86_400)),
            now: Date(), calendar: .current, locale: .current
        )
        let event = try XCTUnwrap(actions.first { $0.kind == .calendar })
        let reminder = try XCTUnwrap(actions.first { $0.kind == .reminder })

        model.askMail.calendarWriter = DetectedAcceptingWriter()
        await model.perform(event)
        XCTAssertEqual(model.status(for: event), .eventAdded)
        XCTAssertNil(model.status(for: reminder))

        model.askMail.calendarWriter = DetectedDenyingWriter()
        await model.perform(reminder)
        XCTAssertEqual(model.status(for: reminder), .failed("Allow reminders access in Settings to add reminders."))
    }

    /// A second tap while the write runs writes nothing; the chip is busy until the write ends.
    func testASecondPerformWhileWritingDoesNotWriteAgain() async throws {
        let model = makeDetectingModel(detector: NoConversationActionDetector())
        let event = try XCTUnwrap(ConversationDetectedAction.actions(
            from: detectedCard(start: Date().addingTimeInterval(86_400)), now: Date(), calendar: .current, locale: .current
        ).first)
        let writer = GatedCountingWriter()
        model.askMail.calendarWriter = writer

        let first = Task { await model.perform(event) }
        await writer.waitUntilWriting()
        XCTAssertTrue(model.isPerforming(event))
        let secondReturned = DetectedFlag()
        let second = Task {
            await model.perform(event)
            secondReturned.value = true
        }
        // A guarded second tap returns at once; an unguarded one reaches the writer.
        for _ in 0..<200 where !secondReturned.value && writer.eventCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        writer.release()
        await second.value
        await first.value

        XCTAssertEqual(writer.eventCount, 1)
        XCTAssertFalse(model.isPerforming(event))
        XCTAssertEqual(model.status(for: event), .eventAdded)
    }

    // MARK: Local detector

    func testLocalDetectorReadsOnlyTheSelectedAccountsMessages() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-detected-actions-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let selected = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("detected_foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([selected, foreign])
        let own = MessageSummary(
            id: MessageID("detected_own"), threadID: ThreadID("thr_detected_own"),
            from: EmailAddress("clinic@example.com"), subject: "Your appointment",
            preview: "Tuesday 09:30", body: "Your appointment on Tuesday at 09:30 is confirmed.", smartCategory: .personal
        )
        let other = MessageSummary(
            id: MessageID("detected_foreign_message"), threadID: ThreadID("thr_detected_foreign"),
            from: EmailAddress("clinic@example.com"), subject: "Your appointment",
            preview: "Tuesday 09:30", body: "Your appointment on Tuesday at 09:30 is confirmed.", smartCategory: .personal
        )
        for (message, accountID, uid) in [(own, selected.id, 1), (other, foreign.id, 2)] {
            _ = try store.commitIncomingMessage(
                message, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: accountID, mailboxPath: "INBOX", uidValidity: 1, uid: uid, notificationEligible: false
            )
        }
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 86_400))
        let json = #"{"relevant":true,"kind":"event","title":"Dentist","hero":"Tuesday 09:30","subtitle":"","fields":[],"startISO":"\#(start)"}"#
        let detector = LocalConversationActionDetector(
            store: store, selectedAccountID: selected.id, provider: { CannedCardProvider(json: json) }
        )

        let ownCard = try await detector.detectedCard(messageID: own.id)
        let foreignCard = try await detector.detectedCard(messageID: other.id)

        XCTAssertEqual(ownCard?.title, "Dentist")
        XCTAssertNotNil(ownCard?.calendarItem)
        XCTAssertNil(foreignCard)

        let unavailable = LocalConversationActionDetector(store: store, selectedAccountID: selected.id, provider: { nil })
        do {
            _ = try await unavailable.detectedCard(messageID: own.id)
            XCTFail("no AI provider is a failure, not \"nothing found\"")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
    }

    /// The hosted pane hides the chip while detecting, shows it once something was found, and
    /// pressing it adds the event and shows Ask Mail's "Added to Calendar".
    func testPaneRendersDetectedChips() async throws {
        let detector = RecordingDetector(card: detectedCard(start: Date().addingTimeInterval(3 * 86_400)), gated: true)
        let model = makeDetectingModel(detector: detector)
        model.askMail.calendarWriter = DetectedAcceptingWriter()
        model.setConversation(planContext(selected: "m2"))
        let pane = HostedConversationAIPane(model: model)
        defer { pane.close() }
        let pending = model.ensureDetection()
        let chipID = "conversation.ai.action.calendar"
        let chipWhileDetecting = await pane.element(chipID, tries: 5)
        XCTAssertNil(chipWhileDetecting, "no chip while detecting")

        detector.release()
        await pending?.value
        let detectedChip = await pane.element(chipID)
        let chip = try XCTUnwrap(detectedChip, "the chip shows once detected")
        XCTAssertTrue(pane.press(chip))

        for _ in 0..<100 where model.status(for: model.detectedActions[0]) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.status(for: model.detectedActions[0]), .eventAdded)
    }

    // MARK: Fixtures

    private func makeDetectingModel(detector: any ConversationActionDetecting) -> ConversationAIPaneModel {
        ConversationAIPaneModel(
            assistant: ThreadAIAssistantViewModel(assistant: PaneAssistant()),
            translation: ThreadTranslationViewModel(handler: UnconfiguredThreadTranslationHandler()),
            askMail: AskMailViewModel(handler: ScopedAskMailHandler()),
            detector: detector
        )
    }

    private func detectedCard(start: Date?, reminderDue: Date? = nil) -> AskMailCardBlock {
        AskMailCardBlock(
            id: "card-m2", kind: start == nil ? .invoice : .event, title: "Tax deadline", badge: nil,
            hero: "31 March", subtitle: "", fields: [],
            source: MailKnowledgeSource(
                id: "S1", messageID: MessageID("m2"), conversationKey: "thread-plan", mailboxPath: "INBOX",
                subject: "Steuererklärung 2025", sender: "Kanton Zürich", sentAt: nil, snippet: ""
            ),
            calendarItem: start.map { AskMailCalendarItem(title: "Tax deadline", start: $0, end: nil, location: nil, notes: nil) },
            reminderItem: reminderDue.map { AskMailReminderItem(title: "Pay Tax deadline", due: $0, notes: nil) }
        )
    }
}

/// Answers with `card` and records which messages it read; when `gated`, holds the answer.
/// The first `failures` requests throw, as AI that isn't ready yet does.
final class RecordingDetector: ConversationActionDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private let card: AskMailCardBlock?
    private let gated: Bool
    private var failures: Int
    private var storage: [MessageID] = []
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []

    init(card: AskMailCardBlock?, gated: Bool = false, failures: Int = 0) {
        self.card = card
        self.gated = gated
        self.failures = failures
    }

    var requests: [MessageID] { lock.withLock { storage } }

    func detectedCard(messageID: MessageID) async throws -> AskMailCardBlock? {
        let (waiters, fails) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
            storage.append(messageID)
            let fails = failures > 0
            if fails { failures -= 1 }
            defer { askedWaiters = [] }
            return (askedWaiters, fails)
        }
        if fails {
            waiters.forEach { $0.resume() }
            throw AIProviderError.unavailable
        }
        waiters.forEach { $0.resume() }
        if gated {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return card
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if !storage.isEmpty { return true }
                askedWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

@MainActor
private final class DetectedFlag {
    var value = false
}

/// Counts events added and holds each write until `release()`.
private final class GatedCountingWriter: AskMailCalendarWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var released = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var writingWaiters: [CheckedContinuation<Void, Never>] = []

    var eventCount: Int { lock.withLock { events } }

    func addEvent(_ item: AskMailCalendarItem) async throws {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            events += 1
            defer { writingWaiters = [] }
            return writingWaiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                gates.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func addReminder(_ item: AskMailReminderItem) async throws {}

    func waitUntilWriting() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if events > 0 { return true }
                writingWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { gates = [] }
            return gates
        }
        pending.forEach { $0.resume() }
    }
}

private struct DetectedAcceptingWriter: AskMailCalendarWriting {
    func addEvent(_ item: AskMailCalendarItem) async throws {}
    func addReminder(_ item: AskMailReminderItem) async throws {}
}

private struct DetectedDenyingWriter: AskMailCalendarWriting {
    func addEvent(_ item: AskMailCalendarItem) async throws { throw AskMailCalendarError.accessDenied }
    func addReminder(_ item: AskMailReminderItem) async throws { throw AskMailCalendarError.accessDenied }
}

private struct CannedCardProvider: AIProvider {
    let id = "canned"
    let displayName = "Canned"
    let chatModelID = "canned-1"
    let capabilities = AICapabilities(
        supportsChat: true, supportsEmbeddings: false, supportsJSONMode: true,
        supportsStreaming: false, maxContextTokens: 4_096, runsLocally: true
    )
    let json: String

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse { throw AIProviderError.unavailable }
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        AIStructuredGenerationResponse(json: Data(json.utf8), modelID: chatModelID, localOnly: true)
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}
