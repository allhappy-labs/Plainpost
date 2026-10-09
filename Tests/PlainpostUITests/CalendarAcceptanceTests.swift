import PlainpostCalendarPresentation
import PlainpostAccountRuntime
import XCTest

@testable import PlainpostNodeTransport
@_spi(DesignPreview) @testable import PlainpostUI

#if os(macOS)
    import AppKit
    import SwiftUI

    /// Release acceptance for the macOS calendar through the real app views:
    /// `PlainpostRootView` is hosted in a native window with the production
    /// `PlainpostCalendarAuthority` and `NodeCalendarClient`, and a fixture
    /// Sync Node answers the signed calendar routes through the closed codec.
    /// Every step is driven through the hosted AppKit/SwiftUI accessibility
    /// tree or native controls, never by mutating view models directly.
    @MainActor
    final class CalendarAcceptanceTests: XCTestCase {
        private var artifacts: AcceptanceArtifacts!

        override func setUp() async throws {
            artifacts = try AcceptanceArtifacts(test: name)
        }

        func testWeekNavigationFiltersTimezoneLayoutAndEditorThroughRootView() async throws {
            try await reportingThrownStep { try await weekNavigationFiltersTimezoneLayoutAndEditor() }
        }

        func testInvitationResponseShowInCalendarAndBackToThreadThroughRootView() async throws {
            try await reportingThrownStep { try await invitationResponseShowInCalendarAndBackToThread() }
        }

        /// XCTest does not print a thrown Swift error's description; record it.
        private func reportingThrownStep(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
            do { try await body() } catch {
                XCTFail("acceptance step failed: \(error)", file: file, line: line)
            }
        }

        private func weekNavigationFiltersTimezoneLayoutAndEditor() async throws {
            let scenario = try AcceptanceScenario()
            let hosted = scenario.hosted
            defer { scenario.close() }

            // Open Calendar from the native sidebar.
            await hosted.settle(20)
            try await hosted.selectSidebarRow("Calendar")
            let week = await hosted.waitFor { $0.contains { HostedAX.identifier($0) == "calendar.week" } }
            XCTAssertTrue(week, "Calendar week view did not open from the sidebar")
            try await hosted.choose("Europe/Zurich", inPopUpContaining: "Asia/Tokyo")
            try await hosted.waitForEvent("standup")

            // Overlaps: three events on the same day render side by side with equal widths.
            let overlapping = try ["review", "planning", "design"].map { try hosted.eventFrame($0) }
            XCTAssertEqual(Set(overlapping.map { $0.minX.rounded() }).count, 3, "overlapping events share a column: \(overlapping)")
            for frame in overlapping.dropFirst() { XCTAssertEqual(frame.width, overlapping[0].width, accuracy: 1.5) }
            let threeColumnDay = try hosted.dayColumnWidth()
            XCTAssertLessThan(overlapping.map(\.maxX).max()! - overlapping.map(\.minX).min()!, threeColumnDay + 1)
            // All-day: the two-day span sits above the timed grid and covers two day columns.
            let allDay = try hosted.eventFrame("offsite")
            XCTAssertEqual(allDay.width, try hosted.dayColumnWidth() * 2 - 6, accuracy: 3)
            XCTAssertTrue(hosted.label(ofEvent: "offsite")?.contains("All day") == true)
            try artifacts.capture(hosted, name: "01-week-overlap-all-day")

            // Week navigation: next week shows only the next occurrence; previous returns.
            try await hosted.press(label: "Next week")
            try await hosted.waitForEvent("product-review-w1")
            XCTAssertNil(hosted.eventElement("review"), "last week's events stay out of the next week")
            let nextWeekRequests = await scenario.node.windowRequests
            XCTAssertTrue(nextWeekRequests.contains { $0.window.start == scenario.node.windowStart(weekOffset: 1, zone: "Europe/Zurich") && $0.window.timezone == "Europe/Zurich" })
            try await hosted.press(label: "Previous week")
            try await hosted.waitForEvent("review")

            // Filter: hiding Personal removes its event and re-lays out the overlap.
            try await hosted.toggleMenuItem("Personal", inMenu: "Calendars")
            let filtered = await hosted.waitFor { _ in hosted.eventElement("design") == nil }
            XCTAssertTrue(filtered, "hidden calendar's event is still visible")
            let twoColumns = try ["review", "planning"].map { try hosted.eventFrame($0) }
            XCTAssertEqual(Set(twoColumns.map { $0.minX.rounded() }).count, 2, "remaining overlap re-lays out in two columns: \(twoColumns)")
            XCTAssertLessThan(try hosted.dayColumnWidth(), threeColumnDay - 20, "day columns narrow when fewer events overlap")
            try artifacts.capture(hosted, name: "02-week-filtered-personal-hidden")
            try await hosted.toggleMenuItem("Personal", inMenu: "Calendars")
            try await hosted.waitForEvent("design")

            // Timezone: the Node is asked for the Tokyo week and events relabel in Tokyo time.
            try await hosted.choose("Asia/Tokyo", inPopUpContaining: "Asia/Tokyo")
            // The app keeps the week containing "now" in the new zone; the Node is asked for exactly that window.
            let tokyoNowWeek = scenario.node.windowStart(containing: scenario.node.now, zone: "Asia/Tokyo")
            await hosted.settle(20)
            let tokyoRequests = await scenario.node.windowRequests
            XCTAssertTrue(tokyoRequests.contains { $0.window.timezone == "Asia/Tokyo" && $0.window.start == tokyoNowWeek }, "no Asia/Tokyo window request for \(tokyoNowWeek)")
            let fixtureWeek = scenario.node.windowStart(weekOffset: 0, zone: "Asia/Tokyo")
            if fixtureWeek != tokyoNowWeek { try await hosted.press(label: fixtureWeek < tokyoNowWeek ? "Previous week" : "Next week") }
            let tokyo = await hosted.waitFor { _ in hosted.label(ofEvent: "review")?.contains(scenario.node.clock("review", zone: "Asia/Tokyo")) == true }
            XCTAssertTrue(tokyo, "event label is not shown in Asia/Tokyo: \(hosted.label(ofEvent: "review") ?? "missing")")
            try artifacts.capture(hosted, name: "03-week-asia-tokyo")
            try await hosted.choose("Europe/Zurich", inPopUpContaining: "Asia/Tokyo")
            try await hosted.press(identifier: "calendar.today")
            try await hosted.waitForEvent("standup")
            XCTAssertTrue(hosted.label(ofEvent: "standup")?.contains(scenario.node.clock("standup", zone: "Europe/Zurich")) == true)

            // Editor Cancel without changes: closes, nothing submitted.
            try await hosted.openEditor(event: "standup")
            try artifacts.capture(window: try XCTUnwrap(hosted.window.attachedSheet), name: "04-editor-open")
            try await hosted.press(label: "Cancel", in: hosted.window.attachedSheet)
            let closedClean = await hosted.waitFor { _ in hosted.window.attachedSheet == nil }
            XCTAssertTrue(closedClean, "unchanged editor did not close on Cancel")

            // Editor Cancel with a draft: asks, discards, nothing submitted.
            try await hosted.openEditor(event: "standup")
            try await hosted.enter("Discarded title", intoFieldLabeled: "Title")
            try await hosted.press(label: "Cancel", in: hosted.window.attachedSheet)
            try await hosted.pressAnywhere(label: "Discard draft")
            let discarded = await hosted.waitFor { _ in hosted.window.attachedSheet == nil }
            XCTAssertTrue(discarded, "discarded draft did not close the editor")
            let afterCancel = await scenario.node.commands
            XCTAssertEqual(afterCancel, [], "Cancel must never submit a command")

            // Editor Save: one edit command at the displayed revision; the week shows the durable result.
            try await hosted.openEditor(event: "standup")
            try await hosted.enter("Team check-in (Room 5)", intoFieldLabeled: "Title")
            try artifacts.capture(window: try XCTUnwrap(hosted.window.attachedSheet), name: "05-editor-draft")
            try await hosted.press(label: "Save", in: hosted.window.attachedSheet)
            let saved = await hosted.waitFor { _ in hosted.window.attachedSheet == nil && hosted.label(ofEvent: "standup")?.hasPrefix("Team check-in (Room 5),") == true }
            XCTAssertTrue(saved, "saved title is not visible: \(hosted.label(ofEvent: "standup") ?? "missing")")
            let commands = await scenario.node.commands
            XCTAssertEqual(commands.count, 1)
            let edit = try XCTUnwrap(commands.first)
            XCTAssertEqual(edit.eventID, "standup"); XCTAssertEqual(edit.connectionID, "conn-a"); XCTAssertEqual(edit.generation, 4)
            XCTAssertEqual(edit.revision, "v1"); XCTAssertEqual(edit.scope, .occurrence); XCTAssertNil(edit.response)
            XCTAssertEqual(edit.edit?.title, "Team check-in (Room 5)")
            XCTAssertEqual(edit.edit?.location, "Room 4", "unchanged fields are sent verbatim")
            XCTAssertEqual(edit.edit?.start.value, "", "an unchanged time is not rewritten")
            let durable = try await scenario.authority.receipts(operationIDs: [edit.operationID])
            XCTAssertEqual(durable.map(\.calendar), [.confirmed])
            XCTAssertEqual(durable.first?.revision, "v2")
            let stored = await scenario.node.event("standup")
            XCTAssertEqual(stored?.title, "Team check-in (Room 5)")
            try artifacts.capture(hosted, name: "06-week-after-save")
            try artifacts.writeAccessibility(hosted, name: "week-after-save")
        }

        private func invitationResponseShowInCalendarAndBackToThread() async throws {
            let scenario = try AcceptanceScenario(initialDestination: .personal)
            let hosted = scenario.hosted
            defer { scenario.close() }
            let target = await scenario.node.targetOccurrence
            let invitation = await scenario.node.invitation
            let subject = AcceptanceMailbox.invitationRow.subject

            // Mail context: the Personal smart mailbox (not the launch default), a
            // 40-conversation list scrolled down, and a conversation that is not first.
            await hosted.settle(30)
            XCTAssertEqual(try hosted.selectedSidebarRowText(), "Personal")
            try hosted.scrollMessageList(toRowContaining: subject)
            await hosted.settle(30)
            let listOffsetBefore = try hosted.messageListOffset()
            XCTAssertGreaterThan(listOffsetBefore, 300, "the message list is scrolled away from the top")
            let listAnchorBefore = try hosted.firstVisibleMessageSubject()
            XCTAssertNotEqual(listAnchorBefore, AcceptanceMailbox.rows[0].subject)
            try await hosted.openMessageRow(containing: subject)

            // The real reader renders the invitation card for its message.
            let card = await hosted.waitFor { $0.contains { HostedAX.identifier($0) == "calendar.invitation.respond.accepted" } }
            XCTAssertTrue(card, "thread invitation card did not render")
            XCTAssertEqual(hosted.window.title, subject, "the selected conversation is open in the reader")
            XCTAssertEqual(hosted.texts(identifier: "calendar.invitation.status"), ["Response status: Awaiting your response"])
            XCTAssertTrue(hosted.allTexts().contains("Work"), "destination calendar is stated before responding")
            try artifacts.writeAccessibility(hosted, name: "07-thread-invitation-card")

            // Respond once; the durable receipt progresses and the card reports it truthfully.
            try await hosted.press(identifier: "calendar.invitation.respond.accepted")
            let sent = await hosted.waitFor(seconds: 20) { _ in hosted.texts(identifier: "calendar.invitation.status") == ["Response status: Response sent"] }
            XCTAssertTrue(sent, "card status: \(hosted.texts(identifier: "calendar.invitation.status"))")
            let commands = await scenario.node.commands
            XCTAssertEqual(commands.count, 1, "exactly one response command")
            let response = try XCTUnwrap(commands.first)
            XCTAssertEqual(response.response, .accepted)
            XCTAssertEqual(response.invitationID, invitation.id)
            XCTAssertEqual(response.eventID, invitation.eventID, "responses name the invitation identity")
            XCTAssertEqual(response.revision, invitation.revision)
            XCTAssertEqual(response.connectionID, "conn-a"); XCTAssertEqual(response.generation, 4); XCTAssertEqual(response.scope, .occurrence)
            let durable = try await scenario.authority.receipts(operationIDs: [response.operationID])
            XCTAssertEqual(durable, [NodeCalendarReceipt(operationID: response.operationID, owner: .email, calendar: .confirmed, delivery: .confirmed, code: "submission_accepted", eventID: invitation.eventID, revision: "v2")])
            let ledger = try XCTUnwrap(try CalendarSnapshotCache(accountID: scenario.authority.accountID, appDataRoot: scenario.appData).loadResponseIntents())
            XCTAssertEqual(ledger[invitation.id]?.command.operationID, response.operationID, "the intent is durable on disk")
            XCTAssertEqual(ledger[invitation.id]?.receipt?.delivery, .confirmed)
            // The chosen response stays selected and inert; a different response would be a new intent.
            let acceptAgain = try XCTUnwrap(hosted.element(identifier: "calendar.invitation.respond.accepted"))
            XCTAssertFalse(HostedAX.enabled(acceptAgain), "a sent response cannot be sent again")
            _ = HostedAX.press(acceptAgain)
            await hosted.settle(20)
            let afterRepeat = await scenario.node.commands
            XCTAssertEqual(afterRepeat.map(\.response), [.accepted], "repeating Accept admits nothing new")
            try artifacts.writeAccessibility(hosted, name: "08-thread-response-sent")

            // Scroll the reader away from the card, then show the exact occurrence in Calendar.
            try hosted.scrollReaderToTop()
            await hosted.settle()
            let readerOffsetBefore = try hosted.readerScrollOffset()
            try await hosted.press(identifier: "calendar.invitation.show")
            let shown = await hosted.waitFor { _ in hosted.element(identifier: "calendar.backToThread") != nil && hosted.eventElement(target.id) != nil }
            XCTAssertTrue(shown, "Show in calendar did not open the occurrence's week")
            XCTAssertNil(hosted.elements().first { HostedAX.identifier($0)?.hasPrefix("calendar.event.product-review-w1.") == true || HostedAX.identifier($0)?.hasPrefix("calendar.event.product-review-w3.") == true }, "only the exact occurrence's week is shown")
            let popover = await hosted.waitFor { _ in NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } }
            XCTAssertTrue(popover, "the selected occurrence opens its details")
            let accepted = await hosted.waitFor { _ in hosted.label(ofEvent: target.id)?.hasSuffix("Accepted") == true }
            XCTAssertTrue(accepted, "calendar shows the same durable response: \(hosted.label(ofEvent: target.id) ?? "missing")")
            let occurrenceRequests = await scenario.node.windowRequests
            XCTAssertTrue(occurrenceRequests.contains { $0.window.start == scenario.node.windowStart(weekOffset: 2, zone: TimeZone.current.identifier) })
            try artifacts.capture(hosted, name: "09-calendar-exact-occurrence")
            if let popoverWindow = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
                try artifacts.capture(window: popoverWindow, name: "10-calendar-occurrence-popover")
            }

            // Back to thread: same mailbox, same conversation, card scrolled into view.
            try await hosted.press(identifier: "calendar.backToThread", in: hosted.window)
            let returned = await hosted.waitFor { _ in hosted.element(identifier: "calendar.invitation.show") != nil && hosted.element(identifier: "calendar.week") == nil }
            XCTAssertTrue(returned, "Back to thread did not restore the reader")
            XCTAssertEqual(try hosted.selectedSidebarRowText(), "Personal", "mailbox selection is preserved")
            XCTAssertEqual(hosted.window.title, subject, "the same conversation is open")
            XCTAssertTrue(hosted.allTexts().contains(subject), "reader shows the selected conversation")
            XCTAssertEqual(hosted.texts(identifier: "calendar.invitation.status"), ["Response status: Response sent"])
            let scrolled = await hosted.waitFor { _ in (try? hosted.readerScrollOffset()) ?? 0 > readerOffsetBefore + 200 }
            XCTAssertTrue(scrolled, "reader did not scroll back to the invitation: \((try? hosted.readerScrollOffset()) ?? -1)")
            let cardFrame = try hosted.frame(identifier: "calendar.invitation.show")
            XCTAssertTrue(try hosted.readerVisibleScreenFrame().intersects(cardFrame), "invitation card is not within the visible reader")
            try artifacts.writeAccessibility(hosted, name: "11-back-to-thread")

            // Back to the list: the same mailbox list, scroll position and selected conversation.
            try await hosted.press(label: "Back", in: hosted.window)
            let listShown = await hosted.waitFor { _ in (try? hosted.messageList()) != nil && hosted.element(identifier: "calendar.invitation.show") == nil }
            XCTAssertTrue(listShown, "Back did not return to the message list")
            let offsetRestored = await hosted.waitFor { _ in abs(((try? hosted.messageListOffset()) ?? -1_000) - listOffsetBefore) < 2 }
            XCTAssertTrue(offsetRestored, "message list scroll offset \((try? hosted.messageListOffset()) ?? -1) != \(listOffsetBefore)")
            XCTAssertEqual(try hosted.firstVisibleMessageSubject(), listAnchorBefore, "the same rows are at the top of the list")
            XCTAssertEqual(try hosted.selectedMessageSubject(), subject, "the conversation stays selected")
            XCTAssertEqual(try hosted.selectedSidebarRowText(), "Personal")
            try artifacts.writeAccessibility(hosted, name: "12-back-to-list")
            let finalCommands = await scenario.node.commands
            XCTAssertEqual(finalCommands.count, 1, "navigation never re-sends a response")
        }
    }

    // MARK: Scenario

    @MainActor
    final class AcceptanceScenario {
        let node: AcceptanceCalendarNode
        let authority: PlainpostCalendarAuthority
        let appData: URL
        let hosted: AcceptanceHost
        init(initialDestination: PlainpostDestination = .smartInbox) throws {
            let now = Date()
            node = AcceptanceCalendarNode(now: now)
            authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: node), accountID: "acceptance-account")
            appData = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-calendar-acceptance-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
            let root = PlainpostRootView(
                viewModel: AcceptanceMailbox.inbox(),
                initialDestination: initialDestination,
                initialInboxMode: InboxDisplayMode.simpleList.rawValue,
                viewModelProvider: { selected in await MainActor.run { AcceptanceMailbox.inbox(selectedMessageID: selected) } },
                calendarAuthority: authority,
                calendarAppDataRoot: appData
            )
            hosted = AcceptanceHost(root, size: NSSize(width: 1_440, height: 900))
        }
        func close() {
            hosted.close()
            let authority = authority
            Task { await authority.invalidate() }
            try? FileManager.default.removeItem(at: appData)
        }
    }

    /// Readable native artifacts: window bitmaps and the hosted AX tree text.
    /// AppKit content caching does not render the mail reader's canvas
    /// material (the bitmap is blank), so reader steps record the AX tree.
    @MainActor
    final class AcceptanceArtifacts {
        let directory: URL
        init(test: String) throws {
            let base: URL
            if let configured = ProcessInfo.processInfo.environment["PLAINPOST_CALENDAR_ACCEPTANCE_ARTIFACTS"], !configured.isEmpty {
                base = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(".build/verification/calendar-acceptance", isDirectory: true)
            }
            let testName = test.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
            directory = base.appendingPathComponent(testName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            print("Calendar acceptance artifacts: " + directory.path)
        }
        func capture(_ hosted: AcceptanceHost, name: String) throws { try capture(window: hosted.window, name: name) }
        func capture(window: NSWindow, name: String) throws {
            window.layoutIfNeeded()
            let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 10_000, "\(name) capture is empty")
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func writeAccessibility(_ hosted: AcceptanceHost, name: String) throws {
            let lines = hosted.axDump().filter { !$0.hasSuffix("|  | ") }
            try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Native host

    enum AcceptanceFailure: LocalizedError, CustomStringConvertible {
        case missing(String)
        var description: String { if case let .missing(what) = self { return "missing " + what }; return "" }
        var errorDescription: String? { description }
    }

    @MainActor
    final class AcceptanceHost {
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
        init<V: View>(_ view: V, size: NSSize) {
            // SwiftUI publishes its hosted AX tree only for assistive clients.
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            hostingView = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
            hostingView.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
        }
        func close() {
            for sheet in [window.attachedSheet].compactMap({ $0 }) { window.endSheet(sheet) }
            NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }.forEach { $0.orderOut(nil) }
            window.orderOut(nil)
        }
        func settle(_ rounds: Int = 10) async {
            for _ in 0..<rounds { try? await Task.sleep(for: .milliseconds(20)) }
            window.layoutIfNeeded()
        }
        func waitFor(seconds: Double = 8, _ condition: ([NSObject]) -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition(elements()) { return true }
                await settle(3)
            }
            return condition(elements())
        }

        // Native views and accessibility

        func views(in root: NSView? = nil) -> [NSView] {
            let roots = root.map { [$0] } ?? visibleWindows().compactMap { $0.contentView?.superview ?? $0.contentView }
            return roots.flatMap { base in base.subviews.flatMap { [$0] + views(in: $0) } }
        }
        func visibleWindows() -> [NSWindow] {
            [window] + NSApp.windows.filter { $0 !== window && $0.isVisible && ($0.sheetParent === window || $0.sheetParent?.sheetParent === window || String(describing: type(of: $0)).contains("Popover")) }
        }
        func elements(in target: NSWindow? = nil) -> [NSObject] { (target.map { [$0] } ?? visibleWindows()).flatMap { HostedAX.elements($0) } }
        func axDump() -> [String] {
            elements().map { element in
                [HostedAX.role(element) ?? "?", HostedAX.identifier(element) ?? "", HostedAX.texts(element).joined(separator: " / ")].joined(separator: " | ")
            }
        }
        func allTexts() -> [String] { elements().flatMap(HostedAX.texts) }
        func element(identifier: String, in target: NSWindow? = nil) -> NSObject? { elements(in: target).first { HostedAX.identifier($0) == identifier } }
        func texts(identifier: String) -> [String] { elements().filter { HostedAX.identifier($0) == identifier }.flatMap(HostedAX.texts) }
        func frame(identifier: String) throws -> NSRect {
            guard let element = element(identifier: identifier), let frame = HostedAX.frame(element) else { throw AcceptanceFailure.missing(identifier) }
            return frame
        }
        func press(identifier: String, in target: NSWindow? = nil) async throws {
            guard let element = element(identifier: identifier, in: target) else { throw AcceptanceFailure.missing(identifier + "\n" + axDump().joined(separator: "\n")) }
            XCTAssertTrue(HostedAX.enabled(element), identifier + " is disabled")
            _ = HostedAX.press(element)
            await settle()
        }
        func press(label: String, in target: NSWindow? = nil) async throws {
            guard let element = elements(in: target).first(where: { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains(label) }) else {
                throw AcceptanceFailure.missing("button " + label + "\n" + axDump().joined(separator: "\n"))
            }
            XCTAssertTrue(HostedAX.enabled(element), label + " is disabled")
            _ = HostedAX.press(element)
            await settle()
        }
        func pressAnywhere(label: String) async throws {
            let found = await waitFor { elements in elements.contains { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains(label) } }
            guard found else { throw AcceptanceFailure.missing("button " + label) }
            try await press(label: label)
        }

        // Sidebar

        private func sidebar() throws -> NSOutlineView {
            let outlines = views(in: hostingView).compactMap { $0 as? NSOutlineView }
            guard let outline = outlines.first(where: { $0.accessibilityLabel() == "Sidebar" }) ?? outlines.first(where: { candidate in (0..<candidate.numberOfRows).contains { rowText(candidate, $0).first == "Favorites" } }) else {
                throw AcceptanceFailure.missing("sidebar outline")
            }
            return outline
        }
        private func rowText(_ outline: NSOutlineView, _ row: Int) -> [String] {
            outline.view(atColumn: 0, row: row, makeIfNecessary: true).map { HostedAX.elements($0).flatMap(HostedAX.texts) } ?? []
        }
        func selectSidebarRow(_ title: String) async throws {
            let outline = try sidebar()
            guard let row = (0..<outline.numberOfRows).first(where: { rowText(outline, $0).first == title }),
                  let rowView = outline.rowView(atRow: row, makeIfNecessary: true) else { throw AcceptanceFailure.missing("sidebar row \(title) in \((0..<outline.numberOfRows).map { rowText(outline, $0) })") }
            outline.scrollRowToVisible(row)
            // Move the sidebar selection with the keyboard, as a user does.
            XCTAssertTrue(window.makeFirstResponder(outline))
            for _ in 0..<outline.numberOfRows where outline.selectedRow != row {
                key(outline.selectedRow < row ? 125 : 126)
                await settle(3)
            }
            await settle(20)
            XCTAssertEqual(outline.selectedRow, row, "keyboard navigation did not select sidebar row " + title)
        }
        func selectedSidebarRowText() throws -> String? {
            let outline = try sidebar()
            return outline.selectedRow >= 0 ? rowText(outline, outline.selectedRow).first : nil
        }
        private func key(_ code: UInt16) {
            let characters = String(Character(UnicodeScalar(code == 125 ? 0xF701 : 0xF700)!))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                window.sendEvent(event)
            }
        }

        // Message list

        func messageList() throws -> NSOutlineView {
            let outlines = views(in: hostingView).compactMap { $0 as? NSOutlineView }.filter { $0.accessibilityLabel() != "Sidebar" }
            guard let list = outlines.first(where: { outline in (0..<outline.numberOfRows).contains { rowText(outline, $0).contains { $0.contains(AcceptanceMailbox.rows[0].subject) } } }) else {
                throw AcceptanceFailure.missing("message list")
            }
            return list
        }
        func rowTexts(_ outline: NSOutlineView, _ row: Int) -> [String] { rowText(outline, row) }
        func messageRowIndex(containing subject: String) throws -> Int {
            let list = try messageList()
            guard let row = (0..<list.numberOfRows).first(where: { rowText(list, $0).contains { $0.contains(subject) } }) else { throw AcceptanceFailure.missing("message row " + subject) }
            return row
        }
        /// Scrolls the native list so the row sits in the lower half of the viewport, away from the top.
        func scrollMessageList(toRowContaining subject: String) throws {
            let list = try messageList()
            let row = try messageRowIndex(containing: subject)
            guard let scrollView = list.enclosingScrollView else { throw AcceptanceFailure.missing("message list scroll view") }
            let rect = list.rect(ofRow: row)
            let y = max(0, rect.midY - scrollView.contentView.bounds.height * 0.6)
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        func firstVisibleMessageSubject() throws -> String? {
            let list = try messageList()
            let visible = list.rows(in: list.visibleRect)
            return (visible.location..<(visible.location + visible.length)).lazy
                .filter { list.rect(ofRow: $0).minY >= list.visibleRect.minY - 1 }
                .compactMap { self.rowText(list, $0).first(where: { $0.hasPrefix("Nadia Rieben, ") }) }
                .first.map { String($0.dropFirst("Nadia Rieben, ".count)) }
        }
        func selectedMessageSubject() throws -> String? {
            let list = try messageList()
            guard list.selectedRow >= 0, let text = rowText(list, list.selectedRow).first(where: { $0.hasPrefix("Nadia Rieben, ") }) else { return nil }
            return String(text.dropFirst("Nadia Rieben, ".count))
        }
        func messageListOffset() throws -> CGFloat {
            guard let scrollView = try messageList().enclosingScrollView else { throw AcceptanceFailure.missing("message list scroll view") }
            return scrollView.contentView.bounds.origin.y
        }
        func openMessageRow(containing subject: String) async throws {
            let list = try messageList()
            let row = try messageRowIndex(containing: subject)
            guard let rowView = list.rowView(atRow: row, makeIfNecessary: false) else { throw AcceptanceFailure.missing("visible row " + subject) }
            window.makeKeyAndOrderFront(nil)
            click(rowView)
            await settle(20)
        }
        private func click(_ view: NSView) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!
                window.sendEvent(event)
            }
        }

        // Calendar controls

        func eventElement(_ id: String) -> NSObject? { elements(in: window).first { HostedAX.identifier($0)?.hasPrefix("calendar.event." + id + ".") == true } }
        func label(ofEvent id: String) -> String? { eventElement(id).flatMap(HostedAX.label) }
        func eventFrame(_ id: String) throws -> NSRect {
            guard let element = eventElement(id), let frame = HostedAX.frame(element) else { throw AcceptanceFailure.missing("event " + id) }
            return frame
        }
        func waitForEvent(_ id: String) async throws {
            let found = await waitFor { _ in eventElement(id) != nil }
            if !found { throw AcceptanceFailure.missing("event " + id + "\n" + axDump().filter { $0.contains("calendar.") }.joined(separator: "\n")) }
        }
        func dayColumnWidth() throws -> CGFloat {
            let pattern = try NSRegularExpression(pattern: "^[A-Z][a-z]+day, [A-Z][a-z]+ [0-9]+$")
            let headers = elements(in: window).filter { element in
                HostedAX.texts(element).contains { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            }.compactMap(HostedAX.frame).sorted { $0.midX < $1.midX }
            guard headers.count == 7, let first = headers.first, let last = headers.last else { throw AcceptanceFailure.missing("seven day headers \(headers)") }
            return (last.midX - first.midX) / 6
        }
        func choose(_ title: String, inPopUpContaining marker: String) async throws {
            guard let popup = views(in: hostingView).compactMap({ $0 as? NSPopUpButton }).first(where: { !$0.pullsDown && $0.itemTitles.contains(marker) }),
                  let menu = popup.menu else { throw AcceptanceFailure.missing("pop-up with " + marker) }
            let index = popup.indexOfItem(withTitle: title)
            guard index >= 0 else { throw AcceptanceFailure.missing("pop-up item " + title) }
            menu.performActionForItem(at: index)
            await settle(20)
            XCTAssertEqual(popup.titleOfSelectedItem, title)
        }
        /// Clicks a SwiftUI menu button (SwiftUI builds the NSMenu only while it
        /// tracks), chooses the item while the menu is open, and ends tracking.
        func toggleMenuItem(_ title: String, inMenu label: String) async throws {
            guard let popup = views(in: hostingView).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.pullsDown && HostedAX.texts($0).contains(label) }) else {
                throw AcceptanceFailure.missing("menu " + label)
            }
            final class Tracking: @unchecked Sendable { var titles: [String] = []; var chosen: NSMenuItem? }
            let tracking = Tracking()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu else { return }
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    tracking.titles = menu.items.map(\.title)
                    tracking.chosen = menu.items.first { $0.title == title }
                    menu.cancelTrackingWithoutAnimation()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            popup.performClick(nil)
            guard let item = tracking.chosen, let menu = item.menu else { throw AcceptanceFailure.missing("menu item \(title) in \(tracking.titles)") }
            menu.performActionForItem(at: menu.index(of: item))
            await settle(20)
        }
        func openEditor(event id: String) async throws {
            guard let element = eventElement(id) else { throw AcceptanceFailure.missing("event " + id) }
            _ = HostedAX.press(element)
            let popover = await waitFor { elements in elements.contains { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains("Edit event") } }
            guard popover else { throw AcceptanceFailure.missing("Edit event in popover\n" + axDump().joined(separator: "\n")) }
            try await press(label: "Edit event")
            let sheet = await waitFor { _ in window.attachedSheet != nil }
            guard sheet else { throw AcceptanceFailure.missing("editor sheet") }
            await settle(10)
        }
        /// Types into the editor field that follows its visible label, through the field editor.
        func enter(_ text: String, intoFieldLabeled label: String) async throws {
            guard let sheet = window.attachedSheet else { throw AcceptanceFailure.missing("editor sheet") }
            let sheetElements = elements(in: sheet)
            guard let labelIndex = sheetElements.firstIndex(where: { HostedAX.role($0) == "AXStaticText" && HostedAX.texts($0) == [label] }),
                  let field = (sheetElements[labelIndex...].first(where: { HostedAX.role($0) == "AXTextField" }) as? NSCell)?.controlView as? NSTextField else {
                throw AcceptanceFailure.missing("text field " + label)
            }
            sheet.makeKeyAndOrderFront(nil)
            XCTAssertTrue(sheet.makeFirstResponder(field))
            guard let editor = field.currentEditor() as? NSTextView else { throw AcceptanceFailure.missing("field editor for " + label) }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            await settle(10)
            XCTAssertEqual(field.stringValue, text)
        }

        // Reader scrolling

        private func readerScrollView() throws -> NSScrollView {
            guard let show = element(identifier: "calendar.invitation.show", in: window), let target = HostedAX.frame(show) else { throw AcceptanceFailure.missing("invitation card") }
            let scrollViews = views(in: hostingView).compactMap { $0 as? NSScrollView }.filter { view in
                guard view.window === window, let document = view.documentView else { return false }
                let screen = window.convertToScreen(document.convert(document.bounds, to: nil))
                return screen.contains(NSPoint(x: target.midX, y: target.midY))
            }
            guard let scrollView = scrollViews.min(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }) else { throw AcceptanceFailure.missing("reader scroll view") }
            return scrollView
        }
        func scrollReaderToTop() throws {
            let scrollView = try readerScrollView()
            let top = scrollView.documentView?.isFlipped == true ? 0 : max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        /// Distance scrolled down from the top of the reader.
        func readerScrollOffset() throws -> CGFloat {
            let scrollView = try readerScrollView()
            let origin = scrollView.contentView.bounds.origin.y
            return scrollView.documentView?.isFlipped == true ? origin : max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height - origin)
        }
        func readerVisibleScreenFrame() throws -> NSRect {
            let scrollView = try readerScrollView()
            return window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
        }
    }

    extension HostedAX {
        static func frame(_ object: NSObject) -> NSRect? {
            if let element = object as? any NSAccessibilityProtocol { return element.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (NSObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
    }

    // MARK: Mailbox fixture

    /// Forty Personal conversations with unique subjects. Only the invitation
    /// conversation (not first, lower in the list) contains the invitation
    /// message; each conversation's reader thread is resolved by the selected
    /// message through the root view's model provider, as in the app.
    enum AcceptanceMailbox {
        static let invitationMessageID = "calendar-invitation"
        static let invitationRowIndex = 24
        static let rows: [MessageRowModel] = (0..<40).map { index in
            let id = index == invitationRowIndex ? "thread-roadmap" : String(format: "thread-%02d", index)
            let subject = index == invitationRowIndex ? "Quarterly roadmap review" : String(format: "Personal note %02d", index)
            return MessageRowModel(
                id: id, sender: "Nadia Rieben", subject: subject, preview: "Conversation \(index)", category: .personal, categoryLabel: "Personal",
                smartPriority: .normal, requiresAction: false, smartConfidence: 0.9, isUnread: false, isPinned: false, dateLabel: "Jul \(index % 28 + 1)",
                sentAt: Date(timeIntervalSince1970: 1_784_000_000 - Double(index) * 3_600), actions: MessageRowActionModel.defaultActions(isUnread: false), threadMessageCount: 1)
        }
        static var invitationRow: MessageRowModel { rows[invitationRowIndex] }

        static func thread(selectedMessageID: String?) -> ThreadDetailModel {
            guard let row = rows.first(where: { $0.id == selectedMessageID }) else {
                return ThreadDetailModel(subject: "No conversation selected", participants: [], summaryStatus: "Not summarized", actionItems: [], availableActions: [])
            }
            guard row.id == invitationRow.id else {
                return ThreadDetailModel(
                    subject: row.subject, participants: [row.sender], summaryStatus: "Not summarized", actionItems: [], availableActions: ["Reply", "Archive"],
                    messages: [ThreadMessageModel(id: row.id, sender: "nadia@example.test", senderDisplayName: row.sender, dateLabel: row.dateLabel, body: .plainText("Note \(row.subject)."))])
            }
            let filler = (1...5).map { index in
                ThreadMessageModel(
                    id: "roadmap-\(index)", sender: "nadia@example.test", senderDisplayName: "Nadia Rieben", dateLabel: "Jul \(10 + index)",
                    body: .plainText((1...40).map { "Agenda note \(index).\($0): keep the roadmap review focused on shipped outcomes." }.joined(separator: "\n")))
            }
            let invitation = ThreadMessageModel(
                id: invitationMessageID, sender: "anna@example.test", senderDisplayName: "Anna Organizer", dateLabel: "8:20 AM",
                body: .plainText("You are invited to the weekly product review."))
            return ThreadDetailModel(
                subject: row.subject, participants: ["Anna Organizer", "Nadia Rieben"], summaryStatus: "Not summarized",
                actionItems: [], availableActions: ["Reply", "Archive"], messages: filler + [invitation])
        }

        @MainActor static func inbox(selectedMessageID: String? = nil) -> InboxViewModel {
            let preview = InboxViewModel.designPreview()
            return InboxViewModel(
                chrome: preview.chrome, sidebarItems: preview.sidebarItems, smartCards: preview.smartCards, classicRows: rows,
                selectedThread: thread(selectedMessageID: selectedMessageID), aiIndexStatus: preview.aiIndexStatus, accountIdentity: preview.accountIdentity)
        }
    }

    // MARK: Fixture Sync Node

    /// Serves the signed calendar routes with durable per-operation receipts,
    /// through the production closed codec, so the app's real authority,
    /// models and views run unchanged.
    actor AcceptanceCalendarNode: NodeSessionRequestSending {
        static let zone = TimeZone(identifier: "Europe/Zurich")!
        nonisolated let now: Date
        private(set) var windowRequests: [NodeCalendarWindowRequest] = []
        private(set) var commands: [NodeCalendarCommand] = []
        private(set) var receiptReads = 0
        private var receipts: [String: NodeCalendarReceipt] = [:]
        private var receiptProgress: [String: Int] = [:]
        private var events: [String: NodeCalendarEvent] = [:]

        /// Fixed events sit mid-week in the Europe/Zurich week containing `now`
        /// (in the display locale's first weekday), so layouts never clip at a
        /// week boundary; the invitation series recurs weekly after it.
        init(now: Date) {
            self.now = now
            var calendar = Calendar.current
            calendar.timeZone = Self.zone
            let weekStart = CalendarWeekLayout.interval(containing: now, calendar: calendar)!.start
            func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
                let midnight = calendar.date(byAdding: .day, value: day, to: weekStart)!
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: midnight)!
            }
            var all: [NodeCalendarEvent] = [
                Self.event("review", "Product review prep", "work", at(2, 9), at(2, 11, 30)),
                Self.event("planning", "Weekly planning", "work", at(2, 9, 30), at(2, 11)),
                Self.event("design", "Design discussion", "personal", at(2, 10), at(2, 12), response: .needsAction),
                Self.allDay("offsite", "Team offsite", "work", at(2, 0), at(4, 0)),
                Self.event("standup", "Team check-in", "work", at(2, 14), at(2, 14, 30), editable: true),
            ]
            for week in 1...3 {
                var occurrence = Self.event("product-review-w\(week)", "Product review", "work", at(7 * week + 3, 15), at(7 * week + 3, 15, 45), response: .needsAction)
                occurrence.recurring = true
                occurrence.recurrenceID = Self.utc(at(7 * week + 3, 15))
                occurrence.messageID = AcceptanceMailbox.invitationMessageID
                occurrence.threadID = "thread-product-review"
                all.append(occurrence)
            }
            events = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            initial = events
        }
        private let initial: [String: NodeCalendarEvent]

        /// The window start the app requests for the week `weekOffset` weeks after the fixture week, in `zone`.
        nonisolated func windowStart(weekOffset: Int, zone: String) -> String {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone(identifier: zone)!
            let anchor = Self.instant(initial["review"]!.start)!.addingTimeInterval(TimeInterval(weekOffset * 7 * 86_400))
            return ISO8601DateFormatter().string(from: CalendarWeekLayout.interval(containing: anchor, calendar: calendar)!.start)
        }
        nonisolated func windowStart(containing date: Date, zone: String) -> String {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone(identifier: zone)!
            return ISO8601DateFormatter().string(from: CalendarWeekLayout.interval(containing: date, calendar: calendar)!.start)
        }
        /// An event's start wall-clock time as the week view labels it in `zone`.
        nonisolated func clock(_ id: String, zone: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US"); formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateFormat = "EEEE, MMMM d, HH:mm z"
            return formatter.string(from: Self.instant(initial[id]!.start)!)
        }

        static let connection = NodeCalendarConnection(
            id: "conn-a", generation: 4, kind: .caldav, sendingMailbox: "mailbox-a", attendeeAddress: "me@example.test", delivery: .email, enabled: true,
            calendars: [
                .init(id: "work", name: "Work", color: "#4A78DF", timezone: "Europe/Zurich", writable: true, scheduling: false),
                .init(id: "personal", name: "Personal", color: "#488A78", timezone: "Europe/Zurich", writable: true, scheduling: false),
            ])

        var targetOccurrence: NodeCalendarEvent { events["product-review-w2"]! }
        var invitation: NodeCalendarInvitation {
            let target = targetOccurrence
            return .init(
                id: "invitation-product-review-w2", eventID: "identity-product-review-w2", messageID: AcceptanceMailbox.invitationMessageID,
                uid: "uid-product-review", organizer: "anna@example.test", attendeeAddress: "me@example.test", recurrenceID: target.recurrenceID,
                method: "REQUEST", revision: "invitation-r1", state: .actionable, sequence: 2, stamp: "20260913T080000Z",
                title: target.title, location: target.location, start: target.start, end: target.end, meetingURL: nil, calendarEventID: target.id)
        }
        func event(_ id: String) -> NodeCalendarEvent? { events[id] }

        func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
            let data: Data
            switch path {
            case "/v1/calendar/capabilities":
                data = try NodeCalendarCodec.encodeFamily(NodeCalendarCapabilities(version: 1, providers: [.caldav], enabled: true), kind: "capabilities")
            case "/v1/calendar/connections/read":
                data = try NodeCalendarCodec.encodeFamily(NodeCalendarConnectionsResult(connections: [Self.connection]), kind: "connections-result")
            case "/v1/calendar/window":
                let request: NodeCalendarWindowRequest = try NodeCalendarCodec.decodeFamily(body, kind: "window-request")
                windowRequests.append(request)
                let formatter = ISO8601DateFormatter()
                guard let start = formatter.date(from: request.window.start), let end = formatter.date(from: request.window.end) else { return Self.status(400, path) }
                let visible = events.values.filter { event in
                    guard let from = Self.instant(event.start), let to = Self.instant(event.end) else { return false }
                    return from < end && to > start
                }.sorted { $0.id < $1.id }
                data = try NodeCalendarCodec.encodeFamily(
                    NodeCalendarWindowSnapshot(events: visible, window: request.window, coverage: "complete", refreshedAt: formatter.string(from: now), failures: [:], nextCursor: ""),
                    kind: "window-result", limit: NodeCalendarCodec.windowResponseLimit)
            case "/v1/calendar/event":
                let request: NodeCalendarEventRequest = try NodeCalendarCodec.decodeFamily(body, kind: "event-request")
                guard let event = events[request.eventID] else { return Self.status(409, path) }
                data = try NodeCalendarCodec.encodeFamily(NodeCalendarEventResult(event: event), kind: "event-result")
            case "/v1/calendar/invitations":
                let request: NodeCalendarInvitationReadRequest = try NodeCalendarCodec.decodeFamily(body, kind: "invitation-read-request")
                let found = request.messageIDs.contains(AcceptanceMailbox.invitationMessageID) ? [invitation] : []
                data = try NodeCalendarCodec.encodeFamily(NodeCalendarInvitationReadResult(invitations: found), kind: "invitation-read-result")
            case "/v1/calendar/commands":
                let request: NodeCalendarCommandRequest = try NodeCalendarCodec.decodeFamily(body, kind: "command-request")
                data = try NodeCalendarCodec.encodeFamily(NodeCalendarCommandResult(receipt: admit(request.command)), kind: "command-result")
            case "/v1/calendar/operations/read":
                let request: NodeCalendarOperationReadRequest = try NodeCalendarCodec.decodeFamily(body, kind: "operation-read-request")
                receiptReads += 1
                let known = request.operationIDs.compactMap { id -> NodeCalendarReceipt? in receipts[id] == nil ? nil : advance(id) }
                data = try NodeCalendarCodec.encodeFamily(
                    NodeCalendarOperationReadResult(receipts: known, unknownOperationIDs: request.operationIDs.filter { receipts[$0] == nil }), kind: "operation-read-result")
            default:
                return Self.status(404, path)
            }
            return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.acceptance.test" + path)!, headers: [:], body: data)
        }

        /// Edits confirm at admission (provider write, no delivery). Responses
        /// are admitted pending and progress one durable phase per status read.
        private func admit(_ command: NodeCalendarCommand) -> NodeCalendarReceipt {
            if let existing = receipts[command.operationID] { return existing }
            commands.append(command)
            if let edit = command.edit, var event = events[command.eventID], event.revision == command.revision {
                event.title = edit.title; event.location = edit.location; event.notes = edit.notes
                if !edit.start.value.isEmpty { event.start = edit.start; event.end = edit.end }
                event.revision = "v\(Int(event.revision.dropFirst()).map { $0 + 1 } ?? 2)"; event.sequence += 1
                events[event.id] = event
                let receipt = NodeCalendarReceipt(operationID: command.operationID, owner: .email, calendar: .confirmed, delivery: .notNeeded, code: "", eventID: event.id, revision: event.revision)
                receipts[command.operationID] = receipt
                return receipt
            }
            let receipt = NodeCalendarReceipt(operationID: command.operationID, owner: .email, calendar: .pending, delivery: .pending, code: "", eventID: command.eventID, revision: command.revision)
            receipts[command.operationID] = receipt
            return receipt
        }

        private func advance(_ id: String) -> NodeCalendarReceipt {
            guard var receipt = receipts[id], let command = commands.first(where: { $0.operationID == id }), let response = command.response else { return receipts[id]! }
            let step = (receiptProgress[id] ?? 0) + 1
            receiptProgress[id] = step
            if step == 1, receipt.calendar == .pending {
                receipt.calendar = .confirmed; receipt.delivery = .inFlight
                let target = invitation.calendarEventID ?? ""
                if var event = events[target] {
                    event.response = response; event.revision = "v2"
                    events[target] = event
                    receipt.revision = event.revision
                }
            } else if step >= 2, receipt.delivery == .inFlight {
                receipt.delivery = .confirmed; receipt.code = "submission_accepted"
            }
            receipts[id] = receipt
            return receipt
        }

        static func status(_ code: Int, _ path: String) -> NodeHTTPResponse {
            NodeHTTPResponse(statusCode: code, url: URL(string: "https://node.acceptance.test" + path)!, headers: [:], body: Data())
        }
        static func utc(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
        static func local(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
            return formatter.string(from: date)
        }
        static func day(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        static func instant(_ time: NodeCalendarTime) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return CalendarWeekLayout.date(time, calendar: calendar)
        }
        static func event(_ id: String, _ title: String, _ calendarID: String, _ start: Date, _ end: Date, response: NodeCalendarParticipation = .accepted, editable: Bool = false) -> NodeCalendarEvent {
            .init(
                id: id, connectionID: "conn-a", calendarID: calendarID, recurrenceID: "", organizer: "anna@example.test", revision: "v1", sequence: 1, stamp: "",
                title: title, location: "Room 4", notes: "", start: .init(kind: .dateTime, value: local(start), timezone: zone.identifier),
                end: .init(kind: .dateTime, value: local(end), timezone: zone.identifier), recurring: false, cancelled: false, attendeeAddress: "me@example.test",
                response: response, canEditOccurrence: editable, canEditSeries: false, canRespond: true, disabledReason: editable ? "" : "Only the organizer can edit this event.",
                threadID: "", messageID: "", providerLink: "")
        }
        static func allDay(_ id: String, _ title: String, _ calendarID: String, _ start: Date, _ end: Date) -> NodeCalendarEvent {
            var event = event(id, title, calendarID, start, end)
            event.start = .init(kind: .date, value: day(start), timezone: zone.identifier)
            event.end = .init(kind: .date, value: day(end), timezone: zone.identifier)
            return event
        }
    }
#endif
