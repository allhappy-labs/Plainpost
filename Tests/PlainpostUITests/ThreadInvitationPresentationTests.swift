import PlainpostCalendarPresentation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import XCTest

@_spi(DesignPreview) @testable import PlainpostUI

#if os(macOS)
    import AppKit
    import SwiftUI
#endif

@MainActor
final class ThreadInvitationPresentationTests: XCTestCase {
    func testPendingResponseDoesNotClaimAcceptance() {
        let receipt = NodeCalendarReceipt(operationID: "op-1", owner: .email,
            calendar: .confirmed, delivery: .pending, code: "", eventID: "e1", revision: "r2")
        XCTAssertEqual(ThreadInvitationViewModel.statusText(receipt: receipt),
            "Calendar saved; response pending")
    }

    func testReceiptStatesHaveDistinctAccurateText() {
        func text(_ calendar: NodeCalendarStepState, _ delivery: NodeCalendarStepState, _ code: String = "", owner: NodeCalendarDeliveryOwner = .email) -> String {
            ThreadInvitationViewModel.statusText(receipt: .init(operationID: "op", owner: owner, calendar: calendar, delivery: delivery, code: code, eventID: "e", revision: "r"))
        }
        let expected: [(String, String)] = [
            (text(.pending, .pending), "Response pending; calendar not saved yet"),
            (text(.pending, .pending, "remap_required"), "Response waiting for a sending mailbox"),
            (text(.inFlight, .pending), "Saving response to calendar"),
            (text(.uncertain, .pending, "confirmation_pending"), "Checking whether the calendar saved your response"),
            (text(.failed, .notNeeded, "conflict"), "Response not saved; the invitation or event changed"),
            (text(.failed, .notNeeded, "stale_generation"), "Response not saved; the calendar connection changed"),
            (text(.failed, .notNeeded, "trust_changed"), "Response not saved; account access changed"),
            (text(.confirmed, .pending, "remap_required"), "Calendar saved; response waiting for a sending mailbox"),
            (text(.confirmed, .inFlight), "Calendar saved; sending response"),
            (text(.confirmed, .uncertain, "acceptance_unknown"), "Response delivery is uncertain"),
            (text(.confirmed, .failed, "delivery_rejected"), "Calendar saved; the mail server rejected the response"),
            (text(.confirmed, .failed, "stale_revision"), "Calendar saved; response not sent because the event changed"),
            (text(.confirmed, .confirmed, "submission_accepted"), "Response sent"),
            (text(.confirmed, .notNeeded, owner: .google), "Response sent"),
            (text(.confirmed, .notNeeded, owner: .caldavServer), "Response sent"),
        ]
        for (actual, wanted) in expected { XCTAssertEqual(actual, wanted) }
        let all = expected.map(\.0)
        XCTAssertEqual(Set(all).count, expected.count - 2, "only provider-owned confirmation shares Response sent")
        for claim in ["accepted", "delivered", "read"] {
            XCTAssertFalse(all.contains { $0.lowercased().contains(claim) }, claim)
        }
    }

    func testNonActionableStatesExplainWithoutActiveButtons() {
        let connection = invitationConnectionFixture()
        let event = invitationEventFixture()
        var cancelledEvent = event; cancelledEvent.cancelled = true
        var readOnly = invitationConnectionFixture(writable: false)
        readOnly.calendars[0].name = "Shared"
        let cases: [(String, NodeCalendarInvitation, NodeCalendarEvent?, [NodeCalendarConnection])] = [
            ("forwarded", invitationFixture(state: .unresolved, attendee: ""), nil, [connection]),
            ("unresolved", invitationFixture(state: .unresolved), nil, [connection]),
            ("pending", invitationFixture(state: .unresolved, revision: "pending_parse", attendee: ""), nil, [connection]),
            ("superseded", invitationFixture(state: .superseded), event, [connection]),
            ("cancelled", invitationFixture(state: .cancelled), event, [connection]),
            ("cancelled event", invitationFixture(), cancelledEvent, [connection]),
            ("informational", invitationFixture(state: .informational, method: "PUBLISH"), nil, [connection]),
            ("unsupported method", invitationFixture(method: "REFRESH"), event, [connection]),
            ("missing mapping", invitationFixture(attendee: "other@example.test"), nil, [connection]),
            ("ambiguous mapping", invitationFixture(), nil, [connection, { var c = connection; c.id = "second"; return c }()]),
            ("read-only", invitationFixture(), event, [readOnly]),
            ("google unavailable", invitationFixture(), nil, [invitationConnectionFixture(kind: .google)]),
        ]
        var explanations: [String: String] = [:]
        for (name, invitation, event, connections) in cases {
            let availability = ThreadInvitationViewModel.availability(invitation: invitation, event: event, connections: connections)
            guard case let .explanation(text) = availability else { return XCTFail("\(name) offered responses") }
            let card = ThreadInvitationCardModel(invitation: invitation, event: event, availability: availability)
            for response in [NodeCalendarParticipation.accepted, .tentative, .declined] {
                XCTAssertFalse(ThreadInvitationViewModel.canRespond(card, response: response), name)
            }
            XCTAssertNil(ThreadInvitationViewModel.destination(card), name)
            XCTAssertNil(ThreadInvitationPresentation.status(card), "\(name) must not ask for a response")
            explanations[name] = text
        }
        XCTAssertEqual(explanations["cancelled"], explanations["cancelled event"])
        XCTAssertEqual(Set(explanations.values).count, cases.count - 1, "each state explains itself distinctly")
        XCTAssertFalse(explanations.values.contains { $0.lowercased().contains("verified organizer") || $0.lowercased().contains("authenticated") })
        guard case .respond = ThreadInvitationViewModel.availability(invitation: invitationFixture(), event: event, connections: [connection]) else {
            return XCTFail("mapped actionable invitation must be respondable")
        }
    }

    func testOnlySafeMeetingLinksAreOffered() {
        XCTAssertEqual(ThreadInvitationPresentation.safeMeetingLink(in: "Room 4 https://meet.example.com/abc-123")?.host, "meet.example.com")
        XCTAssertEqual(ThreadInvitationPresentation.safeMeetingLink(in: "Join: <https://zoom.example.org/j/1?pwd=x>")?.absoluteString, "https://zoom.example.org/j/1?pwd=x")
        for unsafe in [
            "http://meet.example.com/abc", "javascript:alert(1)", "https://user:pass@meet.example.com/",
            "https://127.0.0.1/meet", "https://localhost/meet", "https://meet.example.com:8443/x",
            "https://mеet.example.com/cyrillic", "file:///etc/passwd", "https://printer.local/", "Conference room",
        ] {
            XCTAssertNil(ThreadInvitationPresentation.safeMeetingLink(in: unsafe), unsafe)
        }
    }

    func testCardShowsIdentityTimeAndOccurrenceScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let event = invitationEventFixture(recurrenceID: "2026-09-17T07:30:00Z")
        let card = ThreadInvitationCardModel(invitation: invitationFixture(recurrenceID: "2026-09-17T07:30:00Z"), event: event, availability: .respond(invitationConnectionFixture()))
        XCTAssertEqual(ThreadInvitationPresentation.title(card), "Design review")
        XCTAssertTrue(ThreadInvitationPresentation.timeLabel(card, calendar: calendar).contains("Thursday, September 17, 03:30"))
        XCTAssertEqual(ThreadInvitationPresentation.originalTimezone(card, calendar: calendar), "Original timezone: Europe/Zurich")
        XCTAssertEqual(ThreadInvitationPresentation.scope(card), "Applies to this occurrence only")
        XCTAssertEqual(ThreadInvitationViewModel.destination(card), "Work")
        let detached = ThreadInvitationCardModel(invitation: invitationFixture(recurrenceID: "2026-09-17T07:30:00Z"), event: nil, availability: .respond(invitationConnectionFixture()))
        XCTAssertEqual(ThreadInvitationPresentation.title(detached), "Calendar invitation")
        XCTAssertTrue(ThreadInvitationPresentation.timeLabel(detached, calendar: calendar).hasPrefix("Occurrence · Thursday, September 17, 03:30"))
        XCTAssertEqual(ThreadInvitationViewModel.destination(detached), "Work (or the existing event if it’s already in your calendar)")
    }

    func testWeekSelectionTargetsExactOccurrence() async throws {
        let service = OccurrenceWeekService()
        let now = ISO8601DateFormatter().date(from: "2026-09-16T10:00:00Z")!
        let model = CalendarWeekViewModel(service: service, clock: { now })
        model.timezoneID = "Europe/Zurich"
        let target = OccurrenceWeekService.occurrence(week: 2)
        await model.start(selection: CalendarEventSelection(event: target))
        XCTAssertEqual(model.selectedEventID, target.id)
        XCTAssertEqual(model.selectedEvent?.recurrenceID, target.recurrenceID)
        XCTAssertTrue(try XCTUnwrap(model.interval).contains(try XCTUnwrap(CalendarWeekLayout.date(target.start, calendar: model.calendar))))
        XCTAssertTrue(model.visibleCalendarIDs.contains("team"))
        model.stop()
    }
}

/// A recurring series whose occurrences share title and calendar but differ in
/// opaque ID and original recurrence identity.
actor OccurrenceWeekService: CalendarServing {
    static func occurrence(week: Int) -> NodeCalendarEvent {
        let day = 16 + 7 * week
        let month = day > 30 ? 10 : 9
        let date = String(format: "2026-%02d-%02d", month, month == 10 ? day - 30 : day)
        var event = invitationEventFixture(id: "series-\(week)", title: "Weekly sync", calendarID: "team", start: date + "T09:00:00+02:00", end: date + "T09:30:00+02:00", recurrenceID: date + "T07:00:00Z")
        event.recurring = true
        return event
    }
    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.caldav], enabled: true) }
    func connections() async throws -> [NodeCalendarConnection] {
        var connection = invitationConnectionFixture()
        connection.calendars = [.init(id: "team", name: "Team", color: "#488A78", timezone: "Europe/Zurich", writable: true, scheduling: false)]
        return [connection]
    }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        .init(events: (0...3).map(Self.occurrence), window: request.window, coverage: "complete", refreshedAt: request.window.start, failures: [:], nextCursor: "")
    }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unsupported }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unsupported }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}

#if os(macOS)
    extension ThreadInvitationPresentationTests {
        func testHostedCardExposesControlsStatusAndSingleIntent() async throws {
            let service = InvitationTestService()
            let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
            await model.prepare(messageIDs: ["m1"])
            var shown: CalendarEventSelection?
            let window = hostedWindow(ThreadInvitationCards(model: model, messageID: "m1", showInCalendar: { shown = $0 }), width: 620, height: 420)
            defer { model.stop(); window.orderOut(nil) }
            try await settle()
            var tree = HostedAX.elements(window)
            let labels = tree.flatMap(HostedAX.texts)
            for label in ["Accept", "Maybe", "Decline", "Show in calendar"] {
                XCTAssertTrue(labels.contains(label), "missing \(label): \(labels)")
            }
            XCTAssertTrue(labels.contains { $0.contains("Design review") }, labels.joined(separator: "\n"))
            XCTAssertTrue(labels.contains { $0.contains("me@example.test") }, labels.joined(separator: "\n"))
            XCTAssertTrue(labels.contains { $0.contains("Join meeting (meet.example.com)") }, labels.joined(separator: "\n"))

            let accept = try XCTUnwrap(tree.first { HostedAX.identifier($0) == "calendar.invitation.respond.accepted" })
            XCTAssertEqual(HostedAX.role(accept), "AXButton")
            XCTAssertTrue(HostedAX.press(accept))
            let admitted = await eventually { model.cards.first?.receipt != nil }
            XCTAssertTrue(admitted)
            try await settle()
            tree = HostedAX.elements(window)
            let status = tree.flatMap(HostedAX.texts).filter { $0.hasPrefix("Response status:") }
            XCTAssertEqual(status, ["Response status: Response pending; calendar not saved yet"])
            if let again = tree.first(where: { HostedAX.identifier($0) == "calendar.invitation.respond.accepted" }) {
                XCTAssertFalse(HostedAX.enabled(again), "pending intent keeps responses disabled")
                _ = HostedAX.press(again)
            }
            try await settle()
            let commands = await service.commands
            XCTAssertEqual(commands.count, 1)

            let show = try XCTUnwrap(tree.first { HostedAX.identifier($0) == "calendar.invitation.show" })
            XCTAssertTrue(HostedAX.press(show))
            XCTAssertEqual(shown, CalendarEventSelection(event: invitationEventFixture()))
            print("Thread invitation hosted AX: " + labels.joined(separator: " | "))
        }

        func testHostedWeekNavigatesToOccurrenceAndBackToThread() async throws {
            let now = ISO8601DateFormatter().date(from: "2026-09-16T10:00:00Z")!
            let model = CalendarWeekViewModel(service: OccurrenceWeekService(), clock: { now })
            model.timezoneID = "Europe/Zurich"
            let target = OccurrenceWeekService.occurrence(week: 1)
            var returned = false
            let window = hostedWindow(CalendarWeekView(model: model, selection: CalendarEventSelection(event: target), backToThread: { returned = true }), width: 1200, height: 760)
            defer { model.stop(); window.orderOut(nil) }
            let selected = await eventually { model.selectedEventID == target.id }
            XCTAssertTrue(selected)
            try await settle()
            let tree = HostedAX.elements(window)
            let event = tree.first { HostedAX.identifier($0)?.hasPrefix("calendar.event.\(target.id).") == true }
            XCTAssertNotNil(event, "target occurrence is rendered in its week")
            XCTAssertNil(tree.first { HostedAX.identifier($0)?.hasPrefix("calendar.event.series-0.") == true }, "other weeks' occurrences are not selected")
            let back = try XCTUnwrap(tree.first { HostedAX.identifier($0) == "calendar.backToThread" })
            XCTAssertEqual(HostedAX.role(back), "AXButton")
            XCTAssertTrue(HostedAX.press(back))
            XCTAssertTrue(returned)
        }

        private func hostedWindow<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
            // SwiftUI publishes its hosted AX tree only for assistive clients
            // (the legacy setter is invoked dynamically, as in the week tests).
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            return window
        }

        private func settle() async throws {
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// SwiftUI virtual elements implement the informal NSObject AX API, while
    /// native controls implement NSAccessibilityProtocol.
    @MainActor enum HostedAX {
        static func elements(_ root: NSObject) -> [NSObject] { collect(root, depth: 0) }
        static func label(_ object: NSObject) -> String? { (object as? any NSAccessibilityProtocol)?.accessibilityLabel() ?? value(object, "accessibilityLabel") as? String }
        static func identifier(_ object: NSObject) -> String? { (object as? any NSAccessibilityProtocol)?.accessibilityIdentifier() ?? value(object, "accessibilityIdentifier") as? String }
        static func role(_ object: NSObject) -> String? { (object as? any NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? value(object, "accessibilityRole") as? String }
        static func enabled(_ object: NSObject) -> Bool {
            if let element = object as? any NSAccessibilityProtocol { return element.isAccessibilityEnabled() }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            guard object.responds(to: selector) else { return true }
            typealias Getter = @convention(c) (NSObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        static func press(_ object: NSObject) -> Bool {
            if let control = object as? any NSAccessibilityProtocol { return control.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Press = @convention(c) (NSObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
        static func value(_ object: NSObject) -> String? { (object as? any NSAccessibilityProtocol)?.accessibilityValue() as? String ?? value(object, "accessibilityValue") as? String }
        /// Controls expose names as labels; SwiftUI static text exposes its content as the value.
        static func texts(_ object: NSObject) -> [String] { [label(object), value(object)].compactMap { $0 }.filter { !$0.isEmpty } }
        private static func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        private static func collect(_ object: NSObject, depth: Int) -> [NSObject] {
            guard depth < 40 else { return [] }
            let children = (object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? (value(object, "accessibilityChildren") as? [Any]) ?? []
            return [object] + children.compactMap { $0 as? NSObject }.flatMap { collect($0, depth: depth + 1) }
        }
    }
#endif
