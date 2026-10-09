import Foundation
import PlainpostAccountRuntime
import XCTest

@testable import PlainpostNodeTransport
@_spi(DesignPreview) @testable import PlainpostUI

@MainActor
final class ThreadInvitationViewModelTests: XCTestCase {
    func testDoubleClickAdmitsExactlyOneCommand() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await service.holdNextSubmit()
        let first = Task { await model.respond(invitation: invitation, response: .accepted) }
        await service.waitForHeldSubmit()
        await model.respond(invitation: invitation, response: .accepted)
        await model.respond(invitation: invitation, response: .declined)
        await service.releaseSubmit()
        await first.value
        await model.respond(invitation: invitation, response: .accepted)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.invitationID, "inv-1")
        XCTAssertEqual(command.eventID, invitation.eventID)
        XCTAssertEqual(command.revision, "r1")
        XCTAssertEqual(command.connectionID, "conn")
        XCTAssertEqual(command.generation, 3)
        XCTAssertEqual(command.response, .accepted)
        XCTAssertNil(command.edit)
        XCTAssertEqual(model.cards.first?.receipt?.operationID, command.operationID)
        XCTAssertFalse(ThreadInvitationViewModel.canRespond(try XCTUnwrap(model.cards.first), response: .declined))
        model.stop()
    }

    /// With several writable calendars a new attendee copy needs a chosen
    /// destination before any command is admitted; the choice is sent.
    func testSeveralWritableCalendarsRequireChosenDestination() async throws {
        let service = InvitationTestService(invitations: ["m1": [invitationFixture(resolved: false)]])
        await service.setCalendars([.init(id: "work", name: "Work", color: "#4A78DF", timezone: "Europe/Zurich", writable: true, scheduling: false), .init(id: "home", name: "Home", color: "#488A78", timezone: "Europe/Zurich", writable: true, scheduling: false), .init(id: "shared", name: "Shared", color: "#888888", timezone: "Europe/Zurich", writable: false, scheduling: false)])
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(ThreadInvitationViewModel.destinationOptions(card).map(\.id), ["work", "home"])
        XCTAssertNil(ThreadInvitationViewModel.destination(card), "a single destination is not claimed when the user must choose")
        XCTAssertFalse(ThreadInvitationViewModel.canRespond(card, response: .accepted))
        await model.respond(invitation: card.invitation, response: .accepted)
        var commands = await service.commands
        XCTAssertTrue(commands.isEmpty, "no command before a destination is chosen")
        model.selectDestination(invitationID: card.id, calendarID: "shared")
        XCTAssertNil(model.cards.first?.selectedDestination, "a read-only calendar is never a destination")
        model.selectDestination(invitationID: card.id, calendarID: "home")
        let chosen = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(ThreadInvitationViewModel.destination(chosen), "Home")
        await model.respond(invitation: chosen.invitation, response: .accepted)
        commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.targetCalendarID, "home")
        model.stop()
    }

    /// A single eligible calendar is shown and needs no explicit target.
    func testSingleWritableCalendarIsShownWithoutTarget() async throws {
        let service = InvitationTestService(invitations: ["m1": [invitationFixture(resolved: false)]])
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(ThreadInvitationViewModel.destinationOptions(card).map(\.id), ["work"])
        XCTAssertTrue(ThreadInvitationViewModel.destination(card)?.hasPrefix("Work") == true)
        await model.respond(invitation: card.invitation, response: .tentative)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertNil(commands.first?.targetCalendarID)
        model.stop()
    }

    /// A Node that has not enabled Calendar shows no cards and serves no reads.
    func testDisabledCalendarCapabilityShowsNoCards() async throws {
        let service = InvitationTestService()
        await service.setCapabilityEnabled(false)
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        XCTAssertTrue(model.cards.isEmpty)
        let reads = await service.invitationReads
        XCTAssertEqual(reads, 0)
        model.stop()
    }

    /// The event popover answers a linked invitation through the same
    /// invitation model and durable intent ledger as the thread card.
    func testEventPopoverRespondsThroughTheInvitationIntentPath() async throws {
        let service = InvitationTestService()
        let intents = CalendarResponseIntentStore()
        let week = CalendarWeekViewModel(service: service, clock: Date.init, cache: nil, intents: intents)
        let event = invitationEventFixture()
        let responses = try XCTUnwrap(week.responses(for: event))
        await responses.prepare(messageIDs: [event.messageID])
        let card = try XCTUnwrap(CalendarWeekViewModel.responseCard(for: event, in: responses))
        XCTAssertTrue(ThreadInvitationViewModel.canRespond(card, response: .declined))
        await responses.respond(invitation: card.invitation, response: .declined)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.invitationID, "inv-1")
        XCTAssertEqual(intents["inv-1"]?.command.operationID, commands.first?.operationID)
        var unlinked = event
        unlinked.messageID = ""
        XCTAssertNil(week.responses(for: unlinked), "an event without a linked invitation offers no responses")
        week.stop()
    }

    func testReconnectSettledReceiptIsTerminal() {
        let settled = NodeCalendarReceipt(operationID: "op", owner: .email, calendar: .uncertain, delivery: .failed, code: "stale_generation", eventID: "e", revision: "r")
        XCTAssertTrue(ThreadInvitationViewModel.isTerminal(settled))
        XCTAssertEqual(ThreadInvitationViewModel.statusText(receipt: settled), "Response not confirmed; the calendar connection changed while it was saving")
    }

    /// Disconnect settles a retained response: its receipt is terminal, polling
    /// stops, and a response that was never sent can be given again; an
    /// uncertain send still blocks.
    func testDisconnectSettledReceiptEndsPollingAndReenablesResponding() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await model.respond(invitation: invitation, response: .accepted)
        let operationID = try XCTUnwrap(model.cards.first?.receipt?.operationID)
        await service.advance(operationID, calendar: .inFlight, delivery: .pending, code: "")
        _ = await eventually { model.cards.first?.receipt?.calendar == .inFlight }
        XCTAssertFalse(ThreadInvitationViewModel.canRespond(try XCTUnwrap(model.cards.first), response: .accepted))
        await service.advance(operationID, calendar: .uncertain, delivery: .failed, code: "disconnected")
        let settled = await eventually { model.cards.first?.receipt?.code == "disconnected" }
        XCTAssertTrue(settled)
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertTrue(ThreadInvitationViewModel.isTerminal(try XCTUnwrap(card.receipt)))
        XCTAssertEqual(ThreadInvitationPresentation.status(card), "Response not sent; the calendar was disconnected")
        XCTAssertTrue(ThreadInvitationViewModel.canRespond(card, response: .accepted), "a never-sent response can be given again")
        let reads = await service.receiptReads.count
        try await Task.sleep(for: .milliseconds(80))
        let laterReads = await service.receiptReads.count
        XCTAssertEqual(reads, laterReads, "a disconnect-settled receipt must stop polling")
        model.stop()
        let pendingMail = NodeCalendarReceipt(operationID: "op", owner: .email, calendar: .confirmed, delivery: .failed, code: "disconnected", eventID: "e", revision: "r")
        XCTAssertTrue(ThreadInvitationViewModel.isTerminal(pendingMail))
        XCTAssertEqual(ThreadInvitationViewModel.statusText(receipt: pendingMail), "Calendar saved; response not sent because the calendar was disconnected")
    }

    /// While the calendar is still syncing an invitation can't be answered: the
    /// card says so without a destination picker, polls, and recovers once the
    /// Node resolves it. A response refused as pending is not an admitted intent.
    func testCalendarIndexPendingShowsSyncingAndRecovers() async throws {
        let calendars: [NodeCalendarCollection] = [.init(id: "work", name: "Work", color: "#4A78DF", timezone: "UTC", writable: true, scheduling: false), .init(id: "home", name: "Home", color: "#4A78DF", timezone: "UTC", writable: true, scheduling: false)]
        let pending = invitationFixture(state: .unresolved, revision: "calendar_index_pending", resolved: false)
        let service = InvitationTestService(invitations: ["m1": [pending]])
        await service.setCalendars(calendars)
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(card.availability, .explanation("Calendar is still syncing. Respond when it finishes."))
        XCTAssertTrue(ThreadInvitationViewModel.destinationOptions(card).isEmpty, "no destination picker while syncing")
        for response in [NodeCalendarParticipation.accepted, .tentative, .declined] {
            XCTAssertFalse(ThreadInvitationViewModel.canRespond(card, response: response))
        }
        await service.setInvitations(["m1": [invitationFixture()]])
        let recovered = await eventually { if case .respond = model.cards.first?.availability { return true } else { return false } }
        XCTAssertTrue(recovered, "the card re-reads the invitation while the calendar syncs")
        // A response refused because the index became pending again is not kept.
        await service.failNextSubmit(.calendarIndexPending)
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await model.respond(invitation: invitation, response: .accepted)
        let refused = try XCTUnwrap(model.cards.first)
        XCTAssertNil(refused.intent)
        XCTAssertEqual(refused.message, "Calendar is still syncing. Respond when it finishes.")
        XCTAssertFalse((refused.message ?? "").contains("didn’t receive"))
        XCTAssertFalse((refused.message ?? "").contains("Checking"))
        model.stop()
    }

    func testInvitationLimitIsExplained() {
        let limited = invitationFixture(state: .informational, revision: "invitation_limit", attendee: "", method: "")
        XCTAssertEqual(ThreadInvitationViewModel.availability(invitation: limited, event: nil, connections: []), .explanation("This message has more calendar invitations than Plainpost can show. Respond from your calendar provider."))
    }

    func testUncertainDeliveryIsShownAndNeverRetried() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await model.respond(invitation: invitation, response: .accepted)
        let operationID = try XCTUnwrap(model.cards.first?.receipt?.operationID)
        await service.advance(operationID, calendar: .confirmed, delivery: .uncertain, code: "acceptance_unknown")
        let settled = await eventually { model.cards.first?.receipt?.delivery == .uncertain }
        XCTAssertTrue(settled)
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(ThreadInvitationPresentation.status(card), "Response delivery is uncertain")
        for response in [NodeCalendarParticipation.accepted, .tentative, .declined] {
            XCTAssertFalse(ThreadInvitationViewModel.canRespond(card, response: response))
            await model.respond(invitation: invitation, response: response)
        }
        let reads = await service.receiptReads.count
        try await Task.sleep(for: .milliseconds(80))
        let laterReads = await service.receiptReads.count
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(reads, laterReads, "terminal uncertain delivery must stop polling")
        model.stop()
    }

    func testUpdatedInvitationInvalidatesStaleIntent() async throws {
        // An intent persisted for the old invitation revision whose admission was never confirmed.
        let intents = CalendarResponseIntentStore()
        let staleCommand = NodeCalendarCommand(operationID: "stale-op", connectionID: "conn", generation: 3, eventID: "identity-ev-1", invitationID: "inv-1", revision: "r1", scope: .occurrence, response: .accepted)
        intents["inv-1"] = .init(command: staleCommand, receipt: nil)
        let superseded = invitationFixture(state: .superseded)
        let update = invitationFixture(id: "inv-2", revision: "r2", sequence: 1)
        let service = InvitationTestService(invitations: ["m1": [superseded, update]])
        let model = ThreadInvitationViewModel(service: service, intents: intents, sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        XCTAssertEqual(model.cards.map(\.id), ["inv-1", "inv-2"])
        let stale = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(stale.availability, .explanation("The organizer sent a newer version of this invitation. Respond to the latest one."))
        await model.respond(invitation: superseded, response: .accepted)
        await model.respond(invitation: update, response: .accepted)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.invitationID, "inv-2")
        XCTAssertEqual(commands.first?.revision, "r2")
        XCTAssertNotEqual(commands.first?.operationID, "stale-op")
        // The stale intent is released only after the Node reports it unknown, never resent.
        let released = await eventually { intents["inv-1"] == nil }
        XCTAssertTrue(released)
        let reads = await service.receiptReads
        XCTAssertTrue(reads.contains(["stale-op"]))
        XCTAssertNil(model.cards.first?.message, "a superseded card does not invite a new response")
        model.stop()
    }

    func testUnresolvedInvitationRendersPayloadDetailsWithoutIdentityLookup() async throws {
        var invitation = invitationFixture(resolved: false)
        invitation.title = "Budget review"
        invitation.location = "Room 7"
        invitation.start = .init(kind: .dateTime, value: "2026-09-18T14:00:00+02:00", timezone: "Europe/Zurich")
        invitation.end = .init(kind: .dateTime, value: "2026-09-18T15:00:00+02:00", timezone: "Europe/Zurich")
        invitation.meetingURL = "https://video.example.test/budget"
        let service = InvitationTestService(invitations: ["m1": [invitation]])
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(model.cards.first)
        let eventReads = await service.eventReads
        XCTAssertTrue(eventReads.isEmpty, "the invitation identity is never read as a stored event")
        XCTAssertNil(card.event)
        XCTAssertEqual(ThreadInvitationPresentation.title(card), "Budget review")
        XCTAssertEqual(ThreadInvitationPresentation.location(card), "Room 7")
        XCTAssertTrue(ThreadInvitationPresentation.timeLabel(card, calendar: Calendar(identifier: .gregorian)).contains("September 18"))
        XCTAssertEqual(ThreadInvitationPresentation.meetingLink(card)?.host, "video.example.test")
        guard case .respond = card.availability else { return XCTFail("basic CalDAV stays respondable through the invitation") }
        let google = ThreadInvitationViewModel.availability(invitation: invitation, event: nil, connections: [invitationConnectionFixture(kind: .google)])
        XCTAssertEqual(google, .explanation("Google Calendar hasn’t made this invitation available yet. Check again later or respond in Google Calendar."))
        model.stop()
    }

    func testAmbiguousSubmitFailuresKeepTheFrozenIntentUntilReconciled() async throws {
        for failure in [NodeCalendarError.unauthorized, .invalidResponse, .conflict, .deliveryUncertain] {
            // Admitted, then the answer is lost or unreadable: reconciliation adopts the receipt.
            let admitted = InvitationTestService()
            let model = ThreadInvitationViewModel(service: admitted, intents: .init(), sleep: fastSleep)
            await model.prepare(messageIDs: ["m1"])
            let invitation = try XCTUnwrap(model.cards.first?.invitation)
            await admitted.failNextSubmit(failure, afterAdmission: true)
            await model.respond(invitation: invitation, response: .accepted)
            let operationID = try XCTUnwrap(model.cards.first?.intent?.command.operationID, "\(failure) dropped a possibly admitted intent")
            let reconciled = await eventually { model.cards.first?.receipt?.operationID == operationID }
            XCTAssertTrue(reconciled, "\(failure)")
            await model.respond(invitation: invitation, response: .accepted)
            let admittedCommands = await admitted.commands
            XCTAssertEqual(admittedCommands.count, 1, "\(failure) minted a second intent")
            model.stop()

            // Rejected before admission: released only on the explicit unknown signal.
            let rejected = InvitationTestService()
            let other = ThreadInvitationViewModel(service: rejected, intents: .init(), sleep: fastSleep)
            await other.prepare(messageIDs: ["m1"])
            await rejected.failNextSubmit(failure)
            await other.respond(invitation: invitation, response: .accepted)
            XCTAssertNotNil(other.cards.first?.intent, "\(failure)")
            let released = await eventually { other.cards.first?.intent == nil }
            XCTAssertTrue(released, "\(failure)")
            XCTAssertTrue(ThreadInvitationViewModel.canRespond(try XCTUnwrap(other.cards.first), response: .accepted))
            other.stop()
        }
    }

    func testOperationReadConflictKeepsPossiblyAdmittedIntent() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await service.failNextSubmit(.deliveryUncertain, afterAdmission: true)
        await service.failReceiptReads(.conflict)
        await model.respond(invitation: invitation, response: .declined)
        let reported = await eventually { model.reachabilityMessage != nil }
        XCTAssertTrue(reported)
        let reads = await service.receiptReads.count
        XCTAssertGreaterThan(reads, 0)
        XCTAssertNotNil(model.cards.first?.intent, "a 409 from operations/read is not an unknown operation")
        XCTAssertNil(model.cards.first?.message?.contains("didn’t receive") == true ? "" : nil)
        XCTAssertFalse(ThreadInvitationViewModel.canRespond(try XCTUnwrap(model.cards.first), response: .accepted))
        await service.failReceiptReads(nil)
        let recovered = await eventually { model.cards.first?.receipt != nil }
        XCTAssertTrue(recovered)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        model.stop()
    }

    func testLedgerNeverEvictsUnresolvedOrUncertainIntents() {
        var now = Date(timeIntervalSince1970: 0)
        let store = CalendarResponseIntentStore(limit: 2, clock: { now })
        func intent(_ id: String, _ calendar: NodeCalendarStepState?, _ delivery: NodeCalendarStepState = .confirmed) -> CalendarResponseIntent {
            .init(command: .init(operationID: "op-" + id, connectionID: "conn", generation: 1, eventID: "e", invitationID: id, revision: "r", scope: .occurrence, response: .accepted),
                  receipt: calendar.map { .init(operationID: "op-" + id, owner: .email, calendar: $0, delivery: delivery, code: "", eventID: "e", revision: "r") })
        }
        store["old-success"] = intent("old-success", .confirmed); now += 1
        store["uncertain"] = intent("uncertain", .confirmed, .uncertain); now += 1
        store["newer-success"] = intent("newer-success", .confirmed); now += 1
        XCTAssertNil(store["old-success"], "oldest settled success is evicted first")
        XCTAssertNotNil(store["uncertain"], "uncertain delivery must stay to keep responses disabled")
        XCTAssertNotNil(store["newer-success"])
        store["unadmitted"] = intent("unadmitted", nil); now += 1
        store["pending"] = intent("pending", .pending, .pending); now += 1
        XCTAssertNotNil(store["uncertain"])
        XCTAssertNotNil(store["unadmitted"])
        XCTAssertNotNil(store["pending"])
        XCTAssertNil(store["newer-success"])
    }

    func testLateResultsAreDiscardedAfterAccountSwitch() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await service.holdNextInvitationRead()
        let opening = Task { await model.prepare(messageIDs: ["m1"]) }
        await service.waitForHeldInvitationRead()
        model.stop()
        await service.releaseInvitationRead()
        await opening.value
        XCTAssertTrue(model.cards.isEmpty)

        await model.prepare(messageIDs: ["m1"])
        let invitation = try XCTUnwrap(model.cards.first?.invitation)
        await service.holdNextSubmit()
        await service.failNextSubmit(.conflict)
        let responding = Task { await model.respond(invitation: invitation, response: .declined) }
        await service.waitForHeldSubmit()
        model.stop()
        // The next session opens another thread before the old result arrives.
        await model.prepare(messageIDs: ["m2"])
        let readsBeforeLateResult = await service.invitationReads
        await service.releaseSubmit()
        await responding.value
        let readsAfterLateResult = await service.invitationReads
        XCTAssertEqual(readsAfterLateResult, readsBeforeLateResult, "a late failure must not reload the new session")
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertNil(model.reachabilityMessage)

        let otherAccount = ThreadInvitationViewModel(service: InvitationTestService(invitations: [:]), intents: .init(), sleep: fastSleep)
        await otherAccount.prepare(messageIDs: ["m1"])
        XCTAssertTrue(otherAccount.cards.isEmpty)
    }

    func testReceiptSurvivesViewRecreationAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CalendarSnapshotCache(accountID: "account-a", appDataRoot: root)
        let service = InvitationTestService()
        let first = ThreadInvitationViewModel(service: service, intents: .init(cache: cache), sleep: fastSleep)
        await first.prepare(messageIDs: ["m1"])
        await first.respond(invitation: try XCTUnwrap(first.cards.first?.invitation), response: .accepted)
        let operationID = try XCTUnwrap(first.cards.first?.receipt?.operationID)
        first.stop()
        await service.advance(operationID, calendar: .confirmed, delivery: .confirmed, code: "submission_accepted")

        let reopened = ThreadInvitationViewModel(service: service, intents: .init(cache: cache), sleep: fastSleep)
        await reopened.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(reopened.cards.first)
        XCTAssertEqual(card.receipt?.operationID, operationID)
        XCTAssertEqual(ThreadInvitationPresentation.status(card), "Response sent")
        let reads = await service.receiptReads
        XCTAssertTrue(reads.contains([operationID]))
        await reopened.respond(invitation: card.invitation, response: .accepted)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        reopened.stop()
    }

    func testOldThreadPreparationPollsLazyPlaceholder() async throws {
        let service = InvitationTestService()
        await service.setPendingParseReads(1)
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        let placeholder = try XCTUnwrap(model.cards.first)
        XCTAssertEqual(placeholder.availability, .explanation("Checking this invitation…"))
        XCTAssertFalse(ThreadInvitationViewModel.canRespond(placeholder, response: .accepted))
        let prepared = await eventually { model.cards.first?.invitation.state == .actionable }
        XCTAssertTrue(prepared)
        XCTAssertEqual(model.cards.first?.event?.title, "Design review")
        let eventReads = await service.eventReads
        XCTAssertFalse(eventReads.contains(placeholder.invitation.eventID))
        model.stop()
    }

    func testDistinctEventsStaySeparateCards() async throws {
        let service = InvitationTestService(invitations: [
            "m1": [invitationFixture(id: "inv-a", eventID: "ev-a"), invitationFixture(id: "inv-b", eventID: "ev-b")],
            "m2": [invitationFixture(id: "inv-c", messageID: "m2", eventID: "ev-c")],
        ])
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1", "m2"])
        XCTAssertEqual(model.cards(forMessageID: "m1").map(\.id), ["inv-a", "inv-b"])
        XCTAssertEqual(model.cards(forMessageID: "m2").map(\.id), ["inv-c"])
        XCTAssertEqual(Set(model.cards.compactMap(\.event?.title)).count, 3)
        await model.respond(invitation: model.cards[0].invitation, response: .tentative)
        XCTAssertNotNil(model.cards[0].receipt)
        XCTAssertNil(model.cards[1].intent)
        XCTAssertTrue(ThreadInvitationViewModel.canRespond(model.cards[1], response: .tentative))
        model.stop()
    }

    func testOfflineKeepsLastDurableStatusAndReportsReachability() async throws {
        let service = InvitationTestService()
        let model = ThreadInvitationViewModel(service: service, intents: .init(), sleep: fastSleep)
        await model.prepare(messageIDs: ["m1"])
        await model.respond(invitation: try XCTUnwrap(model.cards.first?.invitation), response: .accepted)
        let receipt = try XCTUnwrap(model.cards.first?.receipt)
        await service.setOffline(true)
        await model.prepare(messageIDs: ["m1"])
        XCTAssertEqual(model.cards.first?.receipt, receipt)
        XCTAssertEqual(model.reachabilityMessage, "Can’t reach your Sync Node. Showing the last known invitation status.")
        model.stop()
    }

    func testSharedAuthorityRefreshesThreadAndCalendar() async throws {
        let sender = AuthorityCalendarSender()
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: sender), accountID: "account-a")
        let week = CalendarWeekViewModel(service: authority, clock: { ISO8601DateFormatter().date(from: "2026-09-16T10:00:00Z")! })
        await week.start()
        await week.waitForPrefetch()
        let thread = ThreadInvitationViewModel(service: authority, intents: .init(), sleep: fastSleep)
        await thread.prepare(messageIDs: ["m1"])
        let card = try XCTUnwrap(thread.cards.first)
        XCTAssertEqual(card.event?.response, .needsAction)
        let windowsBefore = await sender.windowReads
        await thread.respond(invitation: card.invitation, response: .accepted)
        XCTAssertEqual(thread.cards.first?.receipt?.calendar, .pending)
        await sender.confirmAll()
        let refreshed = await eventually {
            let windows = await sender.windowReads
            return thread.cards.first?.receipt?.delivery == .confirmed && thread.cards.first?.event?.response == .accepted && windows > windowsBefore && week.events.first?.response == .accepted
        }
        XCTAssertTrue(refreshed, "thread and calendar must both show the same durable truth")
        XCTAssertEqual(week.events.first?.response, .accepted)
        XCTAssertEqual(ThreadInvitationPresentation.status(try XCTUnwrap(thread.cards.first)), "Response sent")
        let submits = await sender.submits
        XCTAssertEqual(submits, 1)
        let eventRequests = await sender.eventRequests
        XCTAssertFalse(eventRequests.isEmpty)
        XCTAssertEqual(Set(eventRequests), ["ev-1"], "the card reads the resolved stored event, never the invitation identity")
        XCTAssertEqual(thread.cards.first?.invitation.eventID, "identity-ev-1")
        thread.stop(); week.stop()
        await authority.invalidate()
    }
}

// MARK: Fixtures

let fastSleep: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(2)) }

@MainActor func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// `eventID` names the stored projected event. As on a real Node, the
/// invitation's own identity differs and only `calendarEventID` resolves it.
func invitationFixture(id: String = "inv-1", messageID: String = "m1", eventID: String = "ev-1", state: NodeCalendarInvitationState = .actionable, revision: String = "r1", attendee: String = "me@example.test", method: String = "REQUEST", recurrenceID: String = "", sequence: UInt64 = 0, resolved: Bool = true) -> NodeCalendarInvitation {
    .init(id: id, eventID: "identity-" + eventID, messageID: messageID, uid: "uid-" + eventID, organizer: "anna@example.test", attendeeAddress: attendee, recurrenceID: recurrenceID, method: method, revision: revision, state: state, sequence: sequence, stamp: "20260913T080000Z", calendarEventID: resolved ? eventID : nil)
}

func invitationEventFixture(id: String = "ev-1", title: String = "Design review", calendarID: String = "work", start: String = "2026-09-17T09:30:00+02:00", end: String = "2026-09-17T10:30:00+02:00", recurrenceID: String = "", response: NodeCalendarParticipation = .needsAction) -> NodeCalendarEvent {
    .init(id: id, connectionID: "conn", calendarID: calendarID, recurrenceID: recurrenceID, organizer: "anna@example.test", revision: "v1", sequence: 0, stamp: "", title: title, location: "Room 4 https://meet.example.com/abc-123", notes: "", start: .init(kind: .dateTime, value: start, timezone: "Europe/Zurich"), end: .init(kind: .dateTime, value: end, timezone: "Europe/Zurich"), recurring: !recurrenceID.isEmpty, cancelled: false, attendeeAddress: "me@example.test", response: response, canEditOccurrence: false, canEditSeries: false, canRespond: false, disabledReason: "", threadID: "t1", messageID: "m1", providerLink: "")
}

func invitationConnectionFixture(kind: NodeCalendarProviderKind = .caldav, writable: Bool = true) -> NodeCalendarConnection {
    .init(id: "conn", generation: 3, kind: kind, sendingMailbox: "mailbox", attendeeAddress: "me@example.test", delivery: kind == .google ? .google : .email, enabled: true, calendars: [.init(id: "work", name: "Work", color: "#4A78DF", timezone: "Europe/Zurich", writable: writable, scheduling: false)])
}

actor InvitationTestService: CalendarServing {
    private(set) var commands: [NodeCalendarCommand] = []
    private(set) var receiptReads: [[String]] = []
    private(set) var eventReads: [String] = []
    private(set) var invitationReads = 0
    private var invitations: [String: [NodeCalendarInvitation]]
    private var events: [String: NodeCalendarEvent]
    private var server: [String: NodeCalendarReceipt] = [:]
    private var pendingParseReads = 0
    private var offline = false
    private var submitFailure: NodeCalendarError?
    private var admitBeforeFailure = false
    private var receiptFailure: NodeCalendarError?
    private var calendars: [NodeCalendarCollection]?
    private var capabilityEnabled = true
    private let submitGate = TestGate()
    private let readGate = TestGate()

    init(invitations: [String: [NodeCalendarInvitation]]? = nil) {
        self.invitations = invitations ?? ["m1": [invitationFixture()]]
        events = Dictionary(uniqueKeysWithValues: ["ev-1": "Design review", "ev-a": "Planning", "ev-b": "Retrospective", "ev-c": "Offsite"].map { ($0.key, invitationEventFixture(id: $0.key, title: $0.value)) })
    }
    func setInvitations(_ value: [String: [NodeCalendarInvitation]]) { invitations = value }
    func setPendingParseReads(_ count: Int) { pendingParseReads = count }
    func setCalendars(_ value: [NodeCalendarCollection]) { calendars = value }
    func setCapabilityEnabled(_ value: Bool) { capabilityEnabled = value }
    func setOffline(_ value: Bool) { offline = value }
    func failNextSubmit(_ error: NodeCalendarError, afterAdmission: Bool = false) { submitFailure = error; admitBeforeFailure = afterAdmission }
    func failReceiptReads(_ error: NodeCalendarError?) { receiptFailure = error }
    func holdNextSubmit() async { await submitGate.arm() }
    func waitForHeldSubmit() async { await submitGate.waitUntilHeld() }
    func releaseSubmit() async { await submitGate.release() }
    func holdNextInvitationRead() async { await readGate.arm() }
    func waitForHeldInvitationRead() async { await readGate.waitUntilHeld() }
    func releaseInvitationRead() async { await readGate.release() }
    func advance(_ operationID: String, calendar: NodeCalendarStepState, delivery: NodeCalendarStepState, code: String) {
        server[operationID]?.calendar = calendar; server[operationID]?.delivery = delivery; server[operationID]?.code = code
    }

    func capabilities() async throws -> NodeCalendarCapabilities { .init(version: 1, providers: [.caldav], enabled: capabilityEnabled) }
    func connections() async throws -> [NodeCalendarConnection] {
        if offline { throw NodeCalendarError.unavailable }
        var connection = invitationConnectionFixture()
        if let calendars { connection.calendars = calendars }
        return [connection]
    }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unsupported }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot { throw NodeCalendarError.unsupported }
    func event(id: String) async throws -> NodeCalendarEvent {
        eventReads.append(id)
        if offline { throw NodeCalendarError.unavailable }
        guard let event = events[id] else { throw NodeCalendarError.conflict }
        return event
    }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] {
        invitationReads += 1
        await readGate.pass()
        if offline { throw NodeCalendarError.unavailable }
        if pendingParseReads > 0 {
            pendingParseReads -= 1
            return messageIDs.map { invitationFixture(id: "pending-" + $0, messageID: $0, eventID: "pending-" + $0, state: .unresolved, revision: "pending_parse", attendee: "", method: "") }
        }
        return messageIDs.flatMap { invitations[$0] ?? [] }
    }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt {
        commands.append(command)
        await submitGate.pass()
        if let failure = submitFailure, !admitBeforeFailure { submitFailure = nil; throw failure }
        if offline { throw NodeCalendarError.unavailable }
        let receipt = server[command.operationID] ?? .init(operationID: command.operationID, owner: .email, calendar: .pending, delivery: .pending, code: "", eventID: command.eventID, revision: command.revision)
        server[command.operationID] = receipt
        if let failure = submitFailure { submitFailure = nil; admitBeforeFailure = false; throw failure }
        return receipt
    }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] {
        receiptReads.append(operationIDs)
        if offline { throw NodeCalendarError.unavailable }
        if let receiptFailure { throw receiptFailure }
        let found = operationIDs.compactMap { server[$0] }
        guard found.count == operationIDs.count else { throw NodeCalendarError.unknownOperation }
        return found
    }
}

actor TestGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true }
    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            held = continuation
            observers.forEach { $0.resume() }
            observers = []
        }
    }
    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { held?.resume(); held = nil }
}

/// Serves the real signed calendar client routes so the production authority
/// broadcasts receipts to both the thread and week models.
actor AuthorityCalendarSender: NodeSessionRequestSending {
    private(set) var windowReads = 0
    private(set) var submits = 0
    private(set) var eventRequests: [String] = []
    private var receipts: [String: NodeCalendarReceipt] = [:]
    private var response: NodeCalendarParticipation = .needsAction

    func confirmAll() {
        for (id, receipt) in receipts {
            var confirmed = receipt
            confirmed.calendar = .confirmed; confirmed.delivery = .confirmed; confirmed.code = "submission_accepted"; confirmed.revision = "v2"
            receipts[id] = confirmed
        }
        response = .accepted
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let data: Data
        switch path {
        case "/v1/calendar/capabilities":
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarCapabilities(version: 1, providers: [.caldav], enabled: true), kind: "capabilities")
        case "/v1/calendar/connections/read":
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarConnectionsResult(connections: [invitationConnectionFixture()]), kind: "connections-result")
        case "/v1/calendar/window":
            windowReads += 1
            let request: NodeCalendarWindowRequest = try NodeCalendarCodec.decodeFamily(body, kind: "window-request")
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarWindowSnapshot(events: [event()], window: request.window, coverage: "complete", refreshedAt: "2026-09-16T10:00:00Z", failures: [:], nextCursor: ""), kind: "window-result", limit: NodeCalendarCodec.windowResponseLimit)
        case "/v1/calendar/event":
            let request: NodeCalendarEventRequest = try NodeCalendarCodec.decodeFamily(body, kind: "event-request")
            eventRequests.append(request.eventID)
            // As on a real Node, only the stored projected event ID is readable.
            guard request.eventID == "ev-1" else { return NodeHTTPResponse(statusCode: 409, url: URL(string: "https://node.example" + path)!, headers: [:], body: Data()) }
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarEventResult(event: event()), kind: "event-result")
        case "/v1/calendar/invitations":
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarInvitationReadResult(invitations: [invitationFixture()]), kind: "invitation-read-result")
        case "/v1/calendar/commands":
            submits += 1
            let request: NodeCalendarCommandRequest = try NodeCalendarCodec.decodeFamily(body, kind: "command-request")
            let command = request.command
            let receipt = receipts[command.operationID] ?? .init(operationID: command.operationID, owner: .email, calendar: .pending, delivery: .pending, code: "", eventID: command.eventID, revision: command.revision)
            receipts[command.operationID] = receipt
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarCommandResult(receipt: receipt), kind: "command-result")
        case "/v1/calendar/operations/read":
            let request: NodeCalendarOperationReadRequest = try NodeCalendarCodec.decodeFamily(body, kind: "operation-read-request")
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarOperationReadResult(receipts: request.operationIDs.compactMap { receipts[$0] }, unknownOperationIDs: request.operationIDs.filter { receipts[$0] == nil }), kind: "operation-read-result")
        default:
            return NodeHTTPResponse(statusCode: 404, url: URL(string: "https://node.example")!, headers: [:], body: Data())
        }
        return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example" + path)!, headers: [:], body: data)
    }

    private func event() -> NodeCalendarEvent { invitationEventFixture(response: response) }
}
