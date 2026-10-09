import PlainpostCalendarPresentation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI
import XCTest

@testable import PlainpostUI

#if os(macOS)
    import AppKit
#endif

@MainActor final class CalendarEventEditorTests: XCTestCase {
    func testConflictPreservesDirtyDraftAndRequiresExplicitReview() async {
        let service = EditorService()
        await service.setFailure(.conflict)
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.title = "My changed title"
        await model.save(scope: .occurrence)
        XCTAssertEqual(model.draft.title, "My changed title")
        XCTAssertTrue(model.isEditing)
        XCTAssertTrue(model.dirty)
        XCTAssertTrue(model.conflict)
        XCTAssertNil(model.receipt)
        XCTAssertEqual(model.event.revision, "v1")
        XCTAssertEqual(model.latestEvent?.revision, "v2")
        await model.save(scope: .occurrence)
        let count = await service.commands.count
        XCTAssertEqual(count, 1)
        model.reviewAndReapply()
        XCTAssertEqual(model.event.revision, "v2")
        XCTAssertEqual(model.draft.title, "My changed title")
        XCTAssertFalse(model.conflict)
    }
    func testCancellationAndRepeatedSaveKeepOneFrozenOperation() async {
        let service = EditorService()
        await service.setHold()
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.title = "Changed"
        let task = Task { await model.save(scope: .occurrence) }
        await service.waitUntilHeld()
        await model.save(scope: .occurrence)
        task.cancel()
        await service.release()
        await task.value
        XCTAssertTrue(model.isEditing)
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.draft.title, "Changed")
        let first = await service.commands
        XCTAssertEqual(first.count, 1)
        await model.save(scope: .occurrence)
        let second = await service.commands
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[0], second[1])
        XCTAssertEqual(model.receipt?.calendar, .confirmed)
    }
    func testTimeAllDayTimezoneAndDirtyDiscard() async {
        let service = EditorService()
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.title = "Changed"
        model.draft.start = .init(kind: .date, value: "2026-09-15", timezone: "Pacific/Auckland")
        model.draft.end = .init(kind: .date, value: "2026-09-17", timezone: "Pacific/Auckland")
        model.cancel()
        XCTAssertTrue(model.showDiscardConfirmation)
        XCTAssertTrue(model.isEditing)
        await model.save(scope: .occurrence)
        let command = await service.commands.first
        XCTAssertEqual(command?.edit?.start.value, "2026-09-15")
        XCTAssertEqual(command?.edit?.end.value, "2026-09-17")
        XCTAssertEqual(command?.edit?.start.timezone, "Pacific/Auckland")
        XCTAssertFalse(model.isEditing)
    }
    /// A floating event (no zone) stays floating: a title-only save keeps the
    /// provider time, and the week layout places it in the display zone.
    func testFloatingEventSavesTitleWithoutInventingAZone() async {
        let service = EditorService()
        var event = editorEvent()
        event.start = .init(kind: .dateTime, value: "2026-09-14T10:00:00", timezone: "")
        event.end = .init(kind: .dateTime, value: "2026-09-14T11:00:00", timezone: "")
        let model = CalendarEventEditorViewModel(event: event, service: service)
        model.draft.title = "Renamed"
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.canSave(scope: .occurrence))
        await model.save(scope: .occurrence)
        let command = await service.commands.first
        XCTAssertEqual(command?.edit?.title, "Renamed")
        XCTAssertEqual(command?.edit?.start, .init(kind: .dateTime, value: "", timezone: ""))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let placed = CalendarWeekLayout.date(event.start, calendar: tokyo)
        XCTAssertEqual(placed.map { tokyo.component(.hour, from: $0) }, 10)
    }
    func testConflictCanRefreshAfterTemporaryReadFailure() async {
        let service = EditorService()
        await service.setFailure(.conflict)
        await service.setEventFailure(true)
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.title = "Preserved"
        await model.save(scope: .occurrence)
        XCTAssertNil(model.latestEvent)
        await service.setEventFailure(false)
        await model.refreshConflict()
        XCTAssertEqual(model.latestEvent?.revision, "v2")
        let refreshes = await service.windowRefreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.draft.title, "Preserved")
    }
    func testConfirmedSaveWaitsForRefreshedSource() async {
        let service = EditorService()
        await service.setStaleEvent(true)
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.title = "Changed"
        await model.save(scope: .occurrence)
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.draft.title, "Changed")
        await service.setStaleEvent(false)
        await model.save(scope: .occurrence)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2)
        if commands.count == 2 { XCTAssertEqual(commands[0], commands[1]) }
        XCTAssertFalse(model.isEditing)
    }
    func testInvalidIntervalRemainsEditableAndDoesNotCreateOperation() async {
        let service = EditorService()
        let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        model.draft.end = model.draft.start
        await model.save(scope: .occurrence)
        let count = await service.commands.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(model.awaitingConfirmation)
        model.draft.end = editorEvent().end
        model.draft.title = "Fixed interval"
        await model.save(scope: .occurrence)
        XCTAssertEqual(model.receipt?.calendar, .confirmed)
    }
    func testReadOnlyAndDisconnectNeverSubmit() async {
        let service = EditorService()
        var event = editorEvent()
        event.canEditOccurrence = false
        event.canEditSeries = false
        let model = CalendarEventEditorViewModel(event: event, service: service)
        model.draft.title = "Changed"
        await model.save(scope: .occurrence)
        let count = await service.commands.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.isEditing)
        XCTAssertFalse(model.readOnlyReason.isEmpty)
        let disconnected = CalendarEventEditorViewModel(event: editorEvent(), service: service)
        await service.disconnectFixture()
        disconnected.draft.title = "Changed"
        await disconnected.save(scope: .occurrence)
        let after = await service.commands.count
        XCTAssertEqual(after, 0)
        XCTAssertTrue(disconnected.dirty)
    }
}
private func editorEvent() -> NodeCalendarEvent {
    .init(
        id: "opaque", connectionID: "conn", calendarID: "cal", recurrenceID: "",
        organizer: "me@example.test", revision: "v1", sequence: 0, stamp: "", title: "Original",
        location: "Room", notes: "Notes",
        start: .init(
            kind: .dateTime, value: "2026-09-14T10:00:00+02:00", timezone: "Europe/Zurich"),
        end: .init(kind: .dateTime, value: "2026-09-14T11:00:00+02:00", timezone: "Europe/Zurich"),
        recurring: false, cancelled: false, attendeeAddress: "", response: .none,
        canEditOccurrence: true, canEditSeries: true, canRespond: false, disabledReason: "",
        threadID: "", messageID: "", providerLink: "")
}
private actor EditorService: CalendarServing {
    var failure: NodeCalendarError?
    var commands: [NodeCalendarCommand] = []
    var disconnected = false
    var hold = false
    var held: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func setFailure(_ e: NodeCalendarError) { failure = e }
    var staleEvent = false
    func setStaleEvent(_ value: Bool) { staleEvent = value }
    var eventFailure = false
    func setEventFailure(_ value: Bool) { eventFailure = value }
    func disconnectFixture() { disconnected = true }
    func setHold() { hold = true }
    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { observer = $0 } }
    }
    func release() {
        held?.resume()
        held = nil
    }
    func capabilities() async throws -> NodeCalendarCapabilities {
        .init(version: 1, providers: [.google], enabled: true)
    }
    func connections() async throws -> [NodeCalendarConnection] {
        disconnected
            ? []
            : [
                .init(
                    id: "conn", generation: 1, kind: .google, sendingMailbox: "",
                    attendeeAddress: "me@example.test", delivery: .google, enabled: true)
            ]
    }
    var windowRefreshes = 0
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        windowRefreshes += 1
        return .init(
            events: [], window: request.window, coverage: "complete", refreshedAt: "",
            failures: [:], nextCursor: "")
    }
    func configure(_ command: NodeCalendarConnectionCommand) async throws
        -> NodeCalendarConnectionResult
    { throw NodeCalendarError.unsupported }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws
        -> NodeCalendarConnectionResult
    { throw NodeCalendarError.unsupported }
    func event(id: String) async throws -> NodeCalendarEvent {
        if eventFailure { throw NodeCalendarError.unavailable }
        var e = editorEvent()
        e.revision = staleEvent ? "v1" : "v2"
        return e
    }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt {
        commands.append(command)
        if hold {
            hold = false
            await withCheckedContinuation {
                held = $0
                observer?.resume()
                observer = nil
            }
            try Task.checkCancellation()
        }
        if let failure { throw failure }
        return .init(
            operationID: command.operationID, owner: .google, calendar: .confirmed,
            delivery: .notNeeded,
            code: "", eventID: command.eventID, revision: "v2")
    }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}

#if os(macOS)
    extension CalendarEventEditorTests {
        func testHostedEditorShowsDraftAndExplicitConflictReview() async throws {
            let service = EditorService()
            await service.setFailure(.conflict)
            let model = CalendarEventEditorViewModel(event: editorEvent(), service: service)
            model.draft.title = "My preserved title"
            await model.save(scope: .occurrence)
            NSApplication.shared.accessibilitySetValue(
                true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let host = NSHostingView(rootView: CalendarEventEditorView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 720)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
            func labels(_ object: NSObject, depth: Int = 0) -> [String] {
                guard depth < 30 else { return [] }
                func attr(_ name: String) -> Any? {
                    let selector = NSSelectorFromString(name)
                    return object.responds(to: selector)
                        ? object.perform(selector)?.takeUnretainedValue() : nil
                }
                let own = [
                    attr("accessibilityLabel") as? String, attr("accessibilityValue") as? String,
                ]
                .compactMap { $0 }
                return own
                    + ((attr("accessibilityChildren") as? [NSObject]) ?? []).flatMap {
                        labels($0, depth: depth + 1)
                    }
            }
            let rendered = labels(window).joined(separator: "\n")
            XCTAssertTrue(rendered.contains("Save"), rendered)
            XCTAssertTrue(rendered.contains("Cancel"), rendered)
            XCTAssertTrue(rendered.contains("My preserved title"), rendered)
            XCTAssertTrue(rendered.contains("Review and reapply"), rendered)

        }
    }
#endif
