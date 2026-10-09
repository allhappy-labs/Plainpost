import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
import PlainpostAccountRuntime
import PlainpostNodeTransport
@_spi(DesignPreview) @testable import PlainpostUI

@MainActor
final class CalendarWeekViewModelTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
    func testSelectedWindowAndAdjacentPrefetchNeverReplaceSelection() async throws {
        let service = CalendarWeekService()
        let model = CalendarWeekViewModel(service: service, clock: { self.now })
        await model.load(refresh: true)
        let selected = try XCTUnwrap(model.snapshot?.window)
        await model.waitForPrefetch()
        XCTAssertEqual(model.snapshot?.window, selected)
        let windows = await service.windows
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(Set(windows.map(\.start)).count, 3)
        // Only the visible week asks the Node to refresh; adjacent prefetches read.
        let refreshes = await service.refreshes
        XCTAssertEqual(refreshes, [true, false, false])
        model.stop()
    }
    #if os(macOS)
    /// Key-window changes of other windows (mail, settings, sheets) never reload
    /// the calendar week.
    func testOnlyTheCalendarWindowBecomingKeyRefreshes() {
        let calendarWindow = NSWindow(), other = NSWindow()
        XCTAssertTrue(CalendarWeekView.refreshesOnKey(calendarWindow, host: calendarWindow))
        XCTAssertFalse(CalendarWeekView.refreshesOnKey(other, host: calendarWindow))
        XCTAssertFalse(CalendarWeekView.refreshesOnKey(other, host: nil))
    }
    #endif
    func testLateWindowCannotReplaceNewSelectionAndStopRejectsLateResult() async throws {
        let service = CalendarWeekService(); await service.holdNextWindow()
        let model = CalendarWeekViewModel(service: service, clock: { self.now })
        let first = Task { await model.load(refresh: true) }
        await service.waitForHeldWindow()
        await model.moveWeek(by: 1)
        let selected = model.snapshot?.window
        await service.releaseWindow(); await first.value
        XCTAssertEqual(model.snapshot?.window, selected)
        XCTAssertNotNil(selected)
        await service.holdNextWindow()
        let last = Task { await model.load(refresh: true) }
        await service.waitForHeldWindow()
        model.stop(); await service.releaseWindow(); await last.value
        XCTAssertEqual(model.snapshot?.window, selected)
    }
    func testFailureKeepsCachedProjectionAndShowsConnectionErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account-a", appDataRoot: root)
        let service = CalendarWeekService()
        let model = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
        await model.load(refresh: true); await model.waitForPrefetch(); model.stop()
        await service.fail()
        let offline = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
        await offline.load(refresh: false)
        XCTAssertNotNil(offline.snapshot)
        XCTAssertTrue(offline.isCached)
        XCTAssertNotNil(offline.errorMessage)
        XCTAssertEqual(offline.connectionErrors["caldav"], "Reconnect required")
        offline.stop()
    }
    func testSettingsAndSnapshotsAreAccountScopedOwnerOnlyAndPurgeable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CalendarSnapshotCache(accountID: "../account-a", appDataRoot: root)
        let b = CalendarSnapshotCache(accountID: "account-b", appDataRoot: root)
        let settings = CalendarAccountSettings(timezoneID: "Europe/Zurich", visibleCalendarIDs: ["work"], showDeclined: true)
        try a.saveSettings(settings)
        XCTAssertEqual(try a.loadSettings(), settings)
        XCTAssertNil(try b.loadSettings())
        let attributes = try FileManager.default.attributesOfItem(atPath: a.directory.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(a.directory.path.hasPrefix(root.path))
        let contents = try String(contentsOf: a.directory.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(contents.lowercased().contains("password"))
        try a.clear(); XCTAssertNil(try a.loadSettings())
    }
    func testCalendarNavigationLeavesIOSArraysAndMailContextIntact() {
        XCTAssertEqual(PlainpostDestination.iOSPrimaryDestinations.map(\.rawValue), ["smartInbox", "allInboxes", "drafts", "sent", "archive", "trash", "approvalQueue", "labels", "aiIndexStatus", "settings"])
        #if os(macOS)
        XCTAssertTrue(PlainpostDestination.primaryDestinations.contains(.calendar))
        XCTAssertEqual(PlainpostRootWorkspacePresentation.resolve(for: .calendar), .sidebarAndWorkspace)
        #endif
        let context = MailboxListContext.mailbox(destination: .allInboxes, mode: .focusedList)
        var navigation = MailboxWorkspaceNavigationState(initialContext: context)
        navigation.openReader(messageID: "message", from: context)
        let before = navigation
        #if os(macOS)
        XCTAssertTrue(navigation.leave(for: .calendar))
        #endif
        XCTAssertEqual(navigation, before)
    }
}

actor CalendarWeekService: CalendarServing {
    var windows: [NodeCalendarWindow] = []
    var refreshes: [Bool] = []
    var calendarIDs = ["work"]
    func setCalendarIDs(_ ids: [String]) { calendarIDs = ids }
    var shouldFail = false
    var coverage = "complete"
    func partial() { coverage = "partial" }
    var lastCommand: NodeCalendarConnectionCommand?
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func fail() { shouldFail = true }
    func holdNextWindow() { hold = true }
    func waitForHeldWindow() async { if held == nil { await withCheckedContinuation { observer = $0 } } }
    func releaseWindow() { held?.resume(); held = nil }
    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.google, .caldav], enabled: true, google: .init(clientID: "client")) }
    func connections() async throws -> [NodeCalendarConnection] { guard !calendarIDs.isEmpty else { return [] }; return [.init(id: "caldav", generation: 1, kind: .caldav, sendingMailbox: "mail", attendeeAddress: "me@example.test", delivery: .email, enabled: true, calendars: calendarIDs.map { .init(id: $0, name: $0 == "work" ? "Work" : $0, color: "#4A78DF", timezone: "Europe/Zurich", writable: true, scheduling: false) })] }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        windows.append(request.window); refreshes.append(request.refresh)
        if hold { hold = false; await withCheckedContinuation { held = $0; observer?.resume(); observer = nil } }
        if shouldFail { throw NodeCalendarError.unavailable }
        return .init(events: [], window: request.window, coverage: coverage, refreshedAt: request.window.start, failures: ["caldav": "Reconnect required"], nextCursor: "")
    }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { lastCommand = command; throw NodeCalendarError.unavailable }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unavailable }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unavailable }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}


extension CalendarWeekViewModelTests {
    func testCalDAVRequiresExplicitMailboxAndAttendeeAndClearsPassword() async throws {
        let service = CalendarWeekService()
        let settings = CalendarSettingsModel(service: service)
        settings.endpoint = "https://purelymail.com"
        settings.username = "calendar-login"
        settings.password = "private-password"
        XCTAssertFalse(settings.canConnectCalDAV)
        settings.sendingMailboxID = "mailbox-123"
        XCTAssertFalse(settings.canConnectCalDAV)
        settings.attendeeAddress = "me@example.test"
        XCTAssertTrue(settings.canConnectCalDAV)
        await settings.connectCalDAV()
        XCTAssertEqual(settings.password, "")
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertTrue(settings.connections.isEmpty)
    }
    func testCalendarEventAccessibilityIncludesDateTimeCalendarAndStatus() async throws {
        let model = CalendarDesignPreview.model(scenario: "overlap")
        await model.load(refresh: true)
        let event = try XCTUnwrap(model.events.first)
        let label = CalendarEventPopover.accessibilityLabel(event: event, calendarName: "Work", calendar: model.calendar)
        XCTAssertTrue(label.contains(event.title))
        XCTAssertTrue(label.contains("Work"))
        XCTAssertTrue(label.contains("September"))
        XCTAssertTrue(label.contains("Accepted") || label.contains("Needs response"))
        XCTAssertEqual(Set(model.placements.filter { $0.allDaySpan == 0 }.map(\.columnCount)), [3])
        model.stop()
    }
}


extension CalendarWeekViewModelTests {
    func testAccountSessionCalendarAdmissionAndShutdownFenceAuthority() async throws {
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: CalendarSessionTestSender()), accountID: "account-a")
        let model = AccountSessionViewModel(prepareSession: { _ in .active }, calendarAuthorityFactory: { authority })
        model.prepare()
        let activeBy = ContinuousClock.now + .seconds(20)
        while model.presentation != .active, ContinuousClock.now < activeBy { try? await Task.sleep(for: .milliseconds(2)) }
        await model.prepareCalendarAuthority()
        XCTAssertNotNil(model.calendarAuthority)
        await model.shutdownForServerChange()
        XCTAssertNil(model.calendarAuthority)
        do { _ = try await authority.capabilities(); XCTFail("shutdown authority remained active") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
private struct CalendarSessionTestSender: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { throw NodeCalendarError.unavailable }
}


extension CalendarWeekViewModelTests {
    func testStoppingDuringInitialLoadDoesNotRestartPeriodicWork() async {
        let service = CalendarWeekService(); await service.holdNextWindow()
        let model = CalendarWeekViewModel(service: service)
        let opening = Task { await model.start() }
        await service.waitForHeldWindow()
        model.stop(); await service.releaseWindow(); await opening.value
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.isRefreshingPeriodically)
    }
    func testInitialCalendarVisibilitySurvivesOfflineRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account", appDataRoot: root)
        let model = CalendarWeekViewModel(service: CalendarWeekService(), clock: { self.now }, cache: cache)
        await model.load(refresh: true); model.stop()
        let restored = CalendarWeekViewModel(service: CalendarWeekService(), clock: { self.now }, cache: cache)
        XCTAssertEqual(restored.visibleCalendarIDs, ["work"])
    }
    func testReconnectUsesConnectionGenerationAndExplicitMapping() async throws {
        let service = CalendarWeekService()
        let model = CalendarSettingsModel(service: service)
        let connection = NodeCalendarConnection(id: "existing", generation: 7, kind: .caldav, sendingMailbox: "chosen-mailbox", attendeeAddress: "chosen@example.test", delivery: .email, enabled: false)
        model.beginReconnect(connection)
        XCTAssertEqual(model.endpoint, "")
        model.endpoint = "https://dav.example.test"
        model.username = "dav"; model.password = "private"
        await model.connectCalDAV()
        let capturedCommand = await service.lastCommand
        let command = try XCTUnwrap(capturedCommand)
        XCTAssertEqual(command.connectionID, "existing")
        XCTAssertEqual(command.expectedGeneration, 7)
        XCTAssertEqual(command.sendingMailboxID, "chosen-mailbox")
        XCTAssertEqual(command.attendeeAddress, "chosen@example.test")
        XCTAssertEqual(model.password, "")
    }
}


#if os(macOS)
extension CalendarWeekViewModelTests {
    func testHostedWeekExposesNamedControlsAndActionableEvents() async throws {
        for scenario in ["normal", "all-day"] {
            let model = CalendarDesignPreview.model(scenario: scenario)
            if scenario == "all-day" { model.timezoneID = "America/Los_Angeles" }
            await model.load(refresh: true)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let host = NSHostingView(rootView: CalendarWeekView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { model.stop(); window.orderOut(nil) }
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
            // SwiftUI virtual elements implement the informal NSObject AX API,
            // while native controls implement NSAccessibilityProtocol.
            func attribute(_ object: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
                if let element = object as? any NSAccessibilityProtocol {
                    switch name {
                    case .children: return element.accessibilityChildren()
                    case .identifier: return element.accessibilityIdentifier()
                    case .description: return element.accessibilityLabel()
                    case .role: return element.accessibilityRole()?.rawValue
                    default: break
                    }
                }
                let selectorName: String
                switch name { case .children: selectorName = "accessibilityChildren"; case .identifier: selectorName = "accessibilityIdentifier"; case .description: selectorName = "accessibilityLabel"; case .role: selectorName = "accessibilityRole"; default: return nil }
                let selector = NSSelectorFromString(selectorName)
                if object.responds(to: selector) { return object.perform(selector)?.takeUnretainedValue() }
                return object.accessibilityAttributeValue(name)
            }
            func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
                guard depth < 30, let element = value as? NSObject else { return [] }
                return [element] + ((attribute(element, .children) as? [Any]) ?? []).flatMap { elements($0, depth: depth + 1) }
            }
            let tree = elements(window)
            let labels = tree.compactMap { attribute($0, .description) as? String }
            XCTAssertTrue(labels.contains(where: { $0.contains("Previous week") }))
            let event = try XCTUnwrap(tree.first { attribute($0, .identifier) as? String == "calendar.event.\(scenario == "normal" ? "standup" : "trip").0" })
            XCTAssertEqual(attribute(event, .role) as? String, "AXButton")
            XCTAssertTrue((attribute(event, .description) as? String)?.contains("Work") == true)
            if let control = event as? any NSAccessibilityProtocol { XCTAssertTrue(control.accessibilityPerformPress()) }
            else {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                XCTAssertTrue(event.responds(to: selector))
                typealias Press = @convention(c) (NSObject, Selector) -> Bool
                let press = unsafeBitCast(event.method(for: selector), to: Press.self)
                XCTAssertTrue(press(event, selector))
            }
            XCTAssertEqual(model.selectedEventID, scenario == "normal" ? "standup" : "trip")
            let accessibleLabel = try XCTUnwrap(attribute(event, .description) as? String)
            if scenario == "all-day" {
                XCTAssertTrue(accessibleLabel.contains("Monday, September 14 – Thursday, September 17"), accessibleLabel)
            }
            print("Calendar hosted AX \(scenario): \(accessibleLabel)")
        }
    }
}
#endif


extension CalendarWeekViewModelTests {
    func testCalDAVOffersOnlyAuthenticatedSendingMailboxChoices() {
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: CalendarSessionTestSender()), accountID: "account", sendingMailboxes: [.init(id: "selected", name: "Drafts · me@example.test")])
        let model = CalendarSettingsModel(service: authority)
        XCTAssertEqual(model.sendingMailboxes.map(\.id), ["selected"])
        XCTAssertEqual(model.sendingMailboxID, "")
        model.endpoint = "https://dav.example.test"; model.username = "dav"; model.password = "secret"; model.attendeeAddress = "me@example.test"
        model.sendingMailboxID = "unknown"
        XCTAssertFalse(model.canConnectCalDAV)
        model.sendingMailboxID = "selected"
        XCTAssertTrue(model.canConnectCalDAV)
    }

    /// `CalendarSendingMailbox.name` is a Node display label (e.g. "Drafts"), not
    /// necessarily an email, so "Sends as" must use the attendee address the
    /// user entered, never a lookup into the listed mailbox names.
    func testSendsAsLabelUsesAttendeeAddressNotMailboxDisplayName() {
        let connection = NodeCalendarConnection(id: "existing", generation: 1, kind: .caldav, sendingMailbox: "selected", attendeeAddress: "me@example.test", delivery: .email, enabled: true)
        XCTAssertEqual(CalendarSettingsModel.sendsAsLabel(connection), "Sends as me@example.test")
    }

    /// The empty-mailbox state must be able to reach a connectable state: Retry
    /// re-reads the sending-mailbox list, rather than being a dead end.
    func testRetryMailboxDiscoveryReachesConnectableState() async {
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: CalendarSessionTestSender()), accountID: "account", sendingMailboxes: [])
        let model = CalendarSettingsModel(service: authority, refreshSendingMailboxes: { [.init(id: "discovered", name: "Drafts")] })
        XCTAssertTrue(model.sendingMailboxes.isEmpty)
        await model.retryMailboxDiscovery()
        XCTAssertEqual(model.sendingMailboxes.map(\.id), ["discovered"])
        model.endpoint = "https://dav.example.test"; model.username = "dav"; model.password = "secret"
        model.sendingMailboxID = "discovered"; model.attendeeAddress = "me@example.test"
        XCTAssertTrue(model.canConnectCalDAV)
    }

    /// With no refresh path wired (design previews, or a non-session authority
    /// override), Retry still falls back to a plain reload instead of throwing.
    func testRetryMailboxDiscoveryWithoutRefreshPathFallsBackToLoad() async {
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: CalendarSessionTestSender()), accountID: "account", sendingMailboxes: [])
        let model = CalendarSettingsModel(service: authority)
        await model.retryMailboxDiscovery()
        XCTAssertTrue(model.sendingMailboxes.isEmpty)
    }

    /// Retry must be gated like every sibling control: a second call while the
    /// first is still in flight is a no-op, not a second concurrent fetch.
    func testRetryMailboxDiscoveryIgnoresSecondCallWhileFirstIsInFlight() async {
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: CalendarSessionTestSender()), accountID: "account", sendingMailboxes: [])
        let gate = RetryMailboxGate()
        let fetchCount = RetryMailboxFetchCount()
        let model = CalendarSettingsModel(service: authority, refreshSendingMailboxes: {
            await fetchCount.increment()
            await gate.wait()
            return [.init(id: "discovered", name: "Drafts")]
        })
        let first = Task { await model.retryMailboxDiscovery() }
        while !model.isBusy { await Task.yield() }
        await model.retryMailboxDiscovery()
        let countWhileBusy = await fetchCount.value
        XCTAssertEqual(countWhileBusy, 1, "a retry while busy must not start a second fetch")
        await gate.release()
        await first.value
        let countAfterCompletion = await fetchCount.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(countAfterCompletion, 1)
        XCTAssertEqual(model.sendingMailboxes.map(\.id), ["discovered"])
    }
}

private actor RetryMailboxGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor RetryMailboxFetchCount {
    private(set) var value = 0
    func increment() { value += 1 }
}


extension CalendarWeekViewModelTests {
    func testPartialFailureCannotEraseCachedEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account", appDataRoot: root)
        let fixture = CalendarDesignPreview.model(scenario: "normal")
        await fixture.load(refresh: true)
        let snapshot = try XCTUnwrap(fixture.snapshot)
        try cache.save(snapshot)
        try cache.saveSettings(.init(timezoneID: "Europe/Zurich", visibleCalendarIDs: ["work", "personal"], showDeclined: false))
        let service = CalendarWeekService(); await service.partial()
        let model = CalendarWeekViewModel(service: service, clock: { fixture.selectedDate }, cache: cache)
        await model.load(refresh: true)
        XCTAssertEqual(Set(model.snapshot?.events.map(\.id) ?? []), Set(snapshot.events.map(\.id)))
        XCTAssertTrue(model.isCached)
        model.stop(); fixture.stop()
    }
}


extension CalendarWeekViewModelTests {
    func testReturningFromCalendarPreservesSmartBundleReader() {
        var navigation = MailboxWorkspaceNavigationState(initialContext: .smartInboxBundle(.newsletters))
        navigation.openReader(messageID: "message", from: .smartInboxBundle(.newsletters))
        XCTAssertEqual(navigation.calendarReturnContext(destination: .smartInbox, mode: .focusedList), .smartInboxBundle(.newsletters))
        XCTAssertNil(navigation.calendarReturnContext(destination: .allInboxes, mode: .focusedList))
    }
}


extension CalendarWeekViewModelTests {
    func testOfflineCalendarHasCachedIdentityOnlyWithinAdmittedAccount() async throws {
        let model = AccountSessionViewModel(prepareSession: { _ in .active }, calendarAccountIDReader: { "account-a" })
        XCTAssertNil(model.calendarCacheAccountID)
        model.prepare()
        let activeBy = ContinuousClock.now + .seconds(20)
        while model.presentation != .active, ContinuousClock.now < activeBy { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.calendarCacheAccountID, "account-a")
        await model.shutdownForServerChange()
        XCTAssertNil(model.calendarCacheAccountID)
    }
    func testCachedOnlyServiceCannotIssueMutationsAndRestoresCalendarNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account", appDataRoot: root)
        let live = CalendarWeekViewModel(service: CalendarWeekService(), clock: { self.now }, cache: cache)
        await live.load(refresh: true); live.stop()
        let cached = CalendarWeekViewModel(service: CachedCalendarService(), clock: { self.now }, cache: cache)
        await cached.load(refresh: false)
        XCTAssertEqual(cached.connections.first?.calendars.first?.name, "Work")
        XCTAssertNotNil(cached.snapshot)
        do { _ = try await CachedCalendarService().disconnect(.init(operationID: "operation", connectionID: "connection", expectedGeneration: 1)); XCTFail("cached service allowed mutation") } catch { XCTAssertEqual(error as? NodeCalendarError, .unavailable) }
        cached.stop()
    }
}


extension CalendarWeekViewModelTests {
    func testDeclinedAndCalendarFiltersPersistPerAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account", appDataRoot: root)
        let fixture = CalendarDesignPreview.model(scenario: "normal")
        await fixture.load(refresh: true)
        var snapshot = try XCTUnwrap(fixture.snapshot)
        snapshot.events[0].response = .declined
        try cache.save(snapshot)
        try cache.saveSettings(.init(timezoneID: "Europe/Zurich", visibleCalendarIDs: ["work", "personal"], showDeclined: false))
        let model = CalendarWeekViewModel(service: CachedCalendarService(), clock: { fixture.selectedDate }, cache: cache)
        await model.load(refresh: false)
        XCTAssertFalse(model.events.contains { $0.id == snapshot.events[0].id })
        model.showDeclined = true
        XCTAssertTrue(model.events.contains { $0.id == snapshot.events[0].id })
        model.visibleCalendarIDs = []
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertEqual(try cache.loadSettings()?.visibleCalendarIDs, [])
        XCTAssertEqual(try cache.loadSettings()?.showDeclined, true)
        model.stop(); fixture.stop()
    }
}


extension CalendarWeekViewModelTests {
    func testFirstSetupReturnAndRelaunchIncludeNewCalendars() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for relaunch in [false, true] {
            let cache = CalendarSnapshotCache(accountID: "first-setup-\(relaunch)", appDataRoot: root)
            let service = CalendarWeekService()
            await service.setCalendarIDs([])
            var model = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
            await model.load(refresh: true); await model.waitForPrefetch()
            XCTAssertTrue(model.visibleCalendarIDs.isEmpty)
            if relaunch { model.stop(); model = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache) }
            await service.setCalendarIDs(["work"])
            await model.load(refresh: true)
            XCTAssertEqual(model.visibleCalendarIDs, ["work"], "first setup after relaunch=\(relaunch)")
            model.stop()
        }
    }

    func testNewCalendarIsIncludedWithoutRestoringDeliberateExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "filters", appDataRoot: root)
        let service = CalendarWeekService()
        let first = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
        await first.load(refresh: true); await first.waitForPrefetch()
        first.visibleCalendarIDs = []
        await service.setCalendarIDs([])
        await first.load(refresh: true); await first.waitForPrefetch(); first.stop()
        let relaunched = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
        await service.setCalendarIDs(["work", "new"])
        await relaunched.load(refresh: true)
        XCTAssertEqual(relaunched.visibleCalendarIDs, ["new"])
        relaunched.stop()
    }

    func testLegacyFilterSettingsUseCachedCatalogForKnownExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "legacy-filters", appDataRoot: root)
        let service = CalendarWeekService()
        try cache.saveConnections(await service.connections())
        try cache.saveSettings(.init(timezoneID: "Europe/Zurich", visibleCalendarIDs: [], showDeclined: false))
        let model = CalendarWeekViewModel(service: service, clock: { self.now }, cache: cache)
        await service.setCalendarIDs(["work", "new"])
        await model.load(refresh: true)
        XCTAssertEqual(model.visibleCalendarIDs, ["new"])
        model.stop()
    }
}


extension CalendarWeekViewModelTests {
    func testReconnectBlocksOppositeProviderAndCancelRestoresNewSetup() async throws {
        for kind in [NodeCalendarProviderKind.google, .caldav] {
            let service = CalendarWeekService()
            let model = CalendarSettingsModel(service: service)
            let connection = NodeCalendarConnection(id: "existing", generation: 7, kind: kind, sendingMailbox: "mail", attendeeAddress: "me@example.test", delivery: kind == .google ? .google : .email, enabled: false)
            await model.load()
            model.beginReconnect(connection)
            model.endpoint = "https://calendar.example.test"; model.username = "user"; model.password = "secret"
            XCTAssertEqual(model.canConnectGoogle, kind == .google)
            XCTAssertEqual(model.canConnectCalDAV, kind == .caldav)
            if kind == .google {
                await model.connectCalDAV()
                let command = await service.lastCommand
                XCTAssertNil(command, "CalDAV cannot target a Google connection")
            }
            model.cancelReconnect()
            XCTAssertNil(model.reconnectingConnection)
            XCTAssertEqual(model.password, "")
            model.password = "new-password"
            model.sendingMailboxID = "mail"; model.attendeeAddress = "me@example.test"
            XCTAssertTrue(model.canConnectGoogle)
            XCTAssertTrue(model.canConnectCalDAV)
            await model.connectCalDAV()
            let captured = await service.lastCommand
            let command = try XCTUnwrap(captured)
            XCTAssertNil(command.connectionID)
            XCTAssertEqual(command.expectedGeneration, 0)
        }
    }
}


extension CalendarWeekViewModelTests {
    func testAllDayPopoverAndAccessibilityPreserveCivilDatesAcrossTimezones() async throws {
        let fixture = CalendarDesignPreview.model(scenario: "all-day")
        await fixture.load(refresh: true)
        var event = try XCTUnwrap(fixture.events.first)
        fixture.stop()
        for (provider, display) in [("Pacific/Auckland", "America/Los_Angeles"), ("America/Los_Angeles", "Pacific/Auckland")] {
            event.start = .init(kind: .date, value: "2026-09-16", timezone: provider)
            event.end = .init(kind: .date, value: "2026-09-17", timezone: provider)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: display))
            let expected = "All day · Wednesday, September 16 – Thursday, September 17 (exclusive end)"
            XCTAssertEqual(CalendarEventPopover.timeLabel(event: event, calendar: calendar), expected)
            let accessible = CalendarEventPopover.accessibilityLabel(event: event, calendarName: "Work", calendar: calendar)
            XCTAssertTrue(accessible.contains(expected), accessible)
            XCTAssertFalse(accessible.contains("September 15"), accessible)
        }
    }

    func testTimedPopoverAndAccessibilityStillConvertTheInstant() async throws {
        let fixture = CalendarDesignPreview.model(scenario: "normal")
        await fixture.load(refresh: true)
        var event = try XCTUnwrap(fixture.events.first)
        fixture.stop()
        event.start = .init(kind: .dateTime, value: "2026-09-16T09:00:00+12:00", timezone: "Pacific/Auckland")
        event.end = .init(kind: .dateTime, value: "2026-09-16T10:00:00+12:00", timezone: "Pacific/Auckland")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let label = CalendarEventPopover.timeLabel(event: event, calendar: calendar)
        XCTAssertTrue(label.contains("Tuesday, September 15, 14:00"), label)
        XCTAssertTrue(label.contains("Tuesday, September 15, 15:00"), label)
        XCTAssertTrue(CalendarEventPopover.accessibilityLabel(event: event, calendarName: "Work", calendar: calendar).contains(label))
    }
}

extension CalendarWeekViewModelTests {
    func testFailedSetupRowIsNeverShownAsConnected() {
        var connection = NodeCalendarConnection(id: "10000000-0000-4000-8000-000000000001", generation: 1, kind: .caldav, sendingMailbox: "box", attendeeAddress: "me@example.test", delivery: .email, enabled: false)
        XCTAssertEqual(CalendarSettingsModel.connectionStatus(connection), "Setup didn’t finish — connect again to retry")
        connection.enabled = true
        XCTAssertEqual(CalendarSettingsModel.connectionStatus(connection), "Connected")
    }
    func testSetupMessageShowsCalendarLimitFailure() {
        let connection = NodeCalendarConnection(id: "10000000-0000-4000-8000-000000000001", generation: 1, kind: .google, sendingMailbox: "", attendeeAddress: "", delivery: .google, enabled: true)
        XCTAssertEqual(CalendarSettingsModel.setupMessage(.init(connection: connection, operationID: "op", state: .failed, code: .calendarLimit)), "Calendar setup failed: this account has more than 200 calendars.")
        XCTAssertEqual(CalendarSettingsModel.setupMessage(.init(connection: connection, operationID: "op", state: .failed, code: .calendarMetadataLimit)), "Calendar setup failed: the discovered calendar details are too large.")
        XCTAssertEqual(CalendarSettingsModel.setupMessage(.init(connection: connection, operationID: "op", state: .confirmed)), "Calendar connected.")
        XCTAssertEqual(CalendarSettingsModel.setupMessage(.init(connection: connection, operationID: "op", state: .uncertain)), "Finishing setup… Refresh to check.")
    }
}

private actor CapabilityService: CalendarServing {
    let result: Result<Bool, NodeCalendarError>
    init(_ result: Result<Bool, NodeCalendarError>) { self.result = result }
    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.caldav], enabled: try result.get()) }
    func connections() async throws -> [NodeCalendarConnection] { [] }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot { .init(events: [], window: request.window, coverage: "complete", refreshedAt: request.window.start, failures: [:], nextCursor: "") }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unavailable }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unavailable }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}

extension CalendarWeekViewModelTests {
    /// Calendar UI follows the capability probe: an enabled Node shows it, a
    /// Node without calendar assembled shows none (settings explain neutrally),
    /// and only a Node without calendar routes asks for an update.
    func testCalendarUIFollowsCapabilityProbe() async throws {
        let enabled = await CalendarAvailability.probe(CapabilityService(.success(true)), lastKnownEnabled: nil)
        let disabled = await CalendarAvailability.probe(CapabilityService(.success(false)), lastKnownEnabled: true)
        let outdated = await CalendarAvailability.probe(CapabilityService(.failure(.unsupported)), lastKnownEnabled: true)
        let offlineKnown = await CalendarAvailability.probe(CapabilityService(.failure(.unavailable)), lastKnownEnabled: true)
        let offlineNew = await CalendarAvailability.probe(CapabilityService(.failure(.unavailable)), lastKnownEnabled: nil)
        XCTAssertEqual([enabled, disabled, outdated, offlineKnown, offlineNew], [.enabled, .disabled, .updateRequired, .enabled, .unknown])
        XCTAssertEqual([enabled, disabled, outdated, offlineKnown, offlineNew].map(\.showsCalendar), [true, false, false, true, false])
        XCTAssertEqual(disabled.settingsMessage, "Calendar isn’t available on this Sync Node.")
        XCTAssertFalse(disabled.settingsMessage?.contains("Update") ?? true)
        XCTAssertTrue(outdated.settingsMessage?.contains("Update your Sync Node") ?? false)
        #if os(macOS)
        XCTAssertEqual(CalendarAvailability.destination(.calendar, availability: .disabled), .allInboxes)
        XCTAssertEqual(CalendarAvailability.destination(.calendar, availability: .unknown), .calendar)
        #endif
        // The week view of a disabled Node never tells the user to update it.
        let model = CalendarWeekViewModel(service: CapabilityService(.success(false)), clock: { self.now })
        await model.load(refresh: true)
        XCTAssertEqual(model.errorMessage, "Calendar isn’t available on this Sync Node.")
        model.stop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account-a", appDataRoot: root)
        XCTAssertNil(cache.loadAvailability())
        cache.saveAvailability(true)
        XCTAssertEqual(cache.loadAvailability(), true)
    }
    func testSettingsExplainsDisabledNodeWithoutOfferingSetup() async {
        let model = CalendarSettingsModel(service: CapabilityService(.success(false)))
        await model.load()
        XCTAssertEqual(model.availability, .disabled)
        XCTAssertFalse(model.canConnectGoogle)
        model.endpoint = "https://dav.example.test"; model.username = "me"; model.password = "pw"; model.sendingMailboxID = "mail"; model.attendeeAddress = "me@example.test"
        XCTAssertFalse(model.canConnectCalDAV)
        XCTAssertNil(model.errorMessage)
    }
}
