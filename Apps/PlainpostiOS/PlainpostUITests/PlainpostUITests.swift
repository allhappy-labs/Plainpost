import XCTest

@MainActor
final class PlainpostUITests: XCTestCase {
    /// Generous: under host load (a parallel iPad run, other simulators) the
    /// first accessibility snapshot after a launch can stall for well over a
    /// minute. `waitForLaunch` stops early, and fails, once the app is no
    /// longer running, so the budget never hides a crash at launch.
    static let launchTimeout: TimeInterval = 120
    /// How long one existence poll inside `waitForLaunch` lasts.
    private static let launchPollInterval: TimeInterval = 5

    enum LaunchWaitDecision: Equatable {
        case keepWaiting
        case appStopped
        case timedOut
    }

    /// Whether a launch wait goes on: only while the app still runs and the
    /// budget is not spent.
    static func launchWaitDecision(appIsRunning: Bool, elapsed: TimeInterval) -> LaunchWaitDecision {
        guard appIsRunning else { return .appStopped }
        return elapsed < launchTimeout ? .keepWaiting : .timedOut
    }

    /// Waits for the element that proves `app` finished launching. Every test
    /// uses this one wait, so launch tolerance is set in one place.
    @discardableResult
    private func waitForLaunch(
        _ element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let start = Date()
        while true {
            if element.waitForExistence(timeout: Self.launchPollInterval) { return true }
            let running = [.runningForeground, .runningBackground, .runningBackgroundSuspended].contains(app.state)
            switch Self.launchWaitDecision(appIsRunning: running, elapsed: Date().timeIntervalSince(start)) {
            case .keepWaiting:
                continue
            case .appStopped:
                XCTFail("The app stopped running (state \(app.state.rawValue)) before \(element) appeared.", file: file, line: line)
                return false
            case .timedOut:
                XCTFail("\(element) did not appear within \(Int(Self.launchTimeout)) s of launch.\n\(app.debugDescription)", file: file, line: line)
                return false
            }
        }
    }

    /// The split-view root is iPad-only until sub-project 3; iPhone runs the native shell,
    /// covered by MobileMailUITests.
    private func requireSplitViewRoot() throws {
        try XCTSkipIf(isPhone, "The split-view root is iPad-only; MobileMailUITests covers iPhone")
    }

    /// A mailbox row by its subject: a combined button on iPhone, a text on iPad.
    private func mailRow(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        isPhone
            ? app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
            : app.staticTexts[subject]
    }

    /// Back until Mailboxes is on screen (iPhone).
    private func showMailboxes(in app: XCUIApplication) {
        for _ in 0..<4 where !app.navigationBars["Mailboxes"].exists {
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
    }

    private func pullToRefresh(in app: XCUIApplication) {
        // Start on the first mail row: the top of the list's frame is under the category chips,
        // a horizontal scroll view that never reaches the list's refresh control.
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mailbox.row.")).firstMatch
        let start = firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 320)))
    }

    private func waitForArchivedCount(_ count: Int) async throws -> Bool {
        for _ in 0..<30 {
            if try await mailFixture("state").archivedCount == count { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Another simulator session can temporarily foreground a different app
    /// while accessibility queries are in flight. Re-activate Plainpost and
    /// wait for the requested control to become tappable before interacting.
    private func waitForHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        app.activate()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    /// The launch wait tolerates a loaded host but never hides a real
    /// failure: an app that stops running fails at once, and an app that runs
    /// but never shows its first screen fails at the budget.
    func testLaunchWaitKeepsWaitingOnlyWhileTheAppRunsWithinItsBudget() {
        XCTAssertEqual(Self.launchWaitDecision(appIsRunning: true, elapsed: 0), .keepWaiting)
        XCTAssertEqual(Self.launchWaitDecision(appIsRunning: true, elapsed: 60), .keepWaiting,
                       "a loaded host can take longer than the old 45 s")
        XCTAssertEqual(Self.launchWaitDecision(appIsRunning: false, elapsed: 1), .appStopped,
                       "a crash at launch must fail now, not after the budget")
        XCTAssertEqual(Self.launchWaitDecision(appIsRunning: true, elapsed: Self.launchTimeout), .timedOut)
        XCTAssertEqual(Self.launchWaitDecision(appIsRunning: false, elapsed: Self.launchTimeout), .appStopped)
    }

    func testSignedOutLaunchOffersSignInWithApple() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_SIGNED_OUT_UI_ACCEPTANCE"] = "1"
        app.launch()

        XCTAssertTrue(waitForLaunch(app.buttons["account.sign-in-with-apple"], in: app))
    }

    func testCleanLocalLaunchOffersProviderSetupWithoutPlainpostSignIn() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_LOCAL_MAIL_UI_ACCEPTANCE"] = UUID().uuidString
        app.launch()

        XCTAssertTrue(waitForLaunch(app.staticTexts["Connect an account"], in: app))
        XCTAssertFalse(app.buttons["account.sign-in-with-apple"].exists)
        // No account to switch to yet; Settings (Plainpost Account, Sync Node) stays reachable.
        XCTAssertFalse(app.buttons["mailboxes.account-switcher"].exists)
        XCTAssertTrue(app.buttons["account-setup.settings"].exists)
    }

    func testGmailSetupUsesOneFullWidthSignInAction() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_LOCAL_MAIL_UI_ACCEPTANCE"] = UUID().uuidString
        app.launch()

        let gmail = app.buttons["account-setup.provider.gmail"]
        XCTAssertTrue(waitForLaunch(gmail, in: app))
        XCTAssertTrue(waitForHittable(gmail, in: app))
        gmail.tap()

        let signIn = app.buttons["gmail-sign-in-with-google"]
        XCTAssertTrue(waitForLaunch(signIn, in: app))
        XCTAssertTrue(waitForHittable(signIn, in: app))
        XCTAssertGreaterThan(signIn.frame.width, 280)
        XCTAssertEqual(app.textFields.count, 0, "Gmail setup should not ask for a typed name or address")
        XCTAssertEqual(app.secureTextFields.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Gmail setup on compact iPhone"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["gmail-choose-provider"].tap()
        XCTAssertTrue(waitForLaunch(app.buttons["account-setup.provider.gmail"], in: app))
    }

    func testLocalRouteFailureCanRetryWithoutPlainpostSignIn() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_LOCAL_MAIL_UI_ACCEPTANCE"] = UUID().uuidString
        app.launchEnvironment["PLAINPOST_LOCAL_ROUTE_FAIL_ONCE"] = "1"
        app.launch()

        let retry = app.buttons["local-mail.retry-route"]
        XCTAssertTrue(waitForLaunch(retry, in: app))
        XCTAssertTrue(app.staticTexts["Mail unavailable"].exists)
        retry.tap()

        XCTAssertTrue(waitForLaunch(app.staticTexts["Connect an account"], in: app))
        XCTAssertFalse(app.buttons["account.sign-in-with-apple"].exists)
    }

    func testStandaloneDirectMailCleanInstallToRestart() async throws {
        try XCTSkipUnless(isPhone, "The Direct end-to-end run targets the iPhone shell")
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_STANDALONE_MAIL_E2E"] = "1"
        app.launchEnvironment["PLAINPOST_AI_AVAILABILITY_UI_ACCEPTANCE"] = "model-not-ready"
        for key in ["IMAP_PORT", "SMTP_PORT", "IMAP_ANCHOR", "SMTP_ANCHOR"] {
            let name = "PLAINPOST_MAIL_FIXTURE_\(key)"
            app.launchEnvironment[name] = try XCTUnwrap(ProcessInfo.processInfo.environment[name])
        }
        app.launch()
        XCTAssertTrue(waitForLaunch(app.staticTexts["Connect an account"], in: app))
        XCTAssertFalse(app.buttons["account.sign-in-with-apple"].exists)
        XCTAssertTrue(app.buttons["account-setup.settings"].exists)
        XCTAssertFalse(app.staticTexts["Sync Node required"].exists)
        XCTAssertFalse(app.navigationBars["Notification Producer"].exists,
                       "Standalone local mail must not present Node notification enrollment")

        let initial = try await mailFixture("state")
        XCTAssertEqual(initial.smtpDataCount, 0)
        let otherButtons = app.buttons.matching(identifier: "account-setup.provider.other")
        var tappedOther = false
        for attempt in 0..<40 {
            if let visible = otherButtons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                visible.tap()
                tappedOther = true
                break
            }
            if attempt.isMultiple(of: 4) {
                app.swipeUp()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard tappedOther else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Other IMAP setup did not become tappable after scrolling")
            return
        }
        let displayName = app.textFields["account-setup.display-name"]
        if !displayName.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Provider chooser remained after first tap") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
            }
            let other = app.buttons["account-setup.provider.other"].firstMatch
            XCTAssertTrue(other.waitForHittable(timeout: 5), "Other IMAP choice disappeared without opening setup")
            other.tap()
        }
        XCTAssertTrue(displayName.waitForExistence(timeout: 5), app.debugDescription)
        enterSetup("Reader", identifier: "account-setup.display-name", in: app)
        enterSetup("reader@example.test", identifier: "account-setup.email", in: app)
        enterSetup("reader@example.test", identifier: "account-setup.username", in: app)
        enterSetup("127.0.0.1", identifier: "account-setup.imap-host", in: app)
        enterSetup(try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_MAIL_FIXTURE_IMAP_PORT"]), identifier: "account-setup.imap-port", in: app, replacing: true)
        enterSetup("incoming", identifier: "account-setup.imap-password", in: app, secure: true)
        enterSetup("127.0.0.1", identifier: "account-setup.smtp-host", in: app)
        enterSetup(try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_MAIL_FIXTURE_SMTP_PORT"]), identifier: "account-setup.smtp-port", in: app, replacing: true)
        enterSetup("outgoing", identifier: "account-setup.smtp-password", in: app, secure: true)
        let connect = app.buttons["Connect Account"]
        XCTAssertTrue(connect.waitForEnabled(timeout: 10))
        let dismissKeyboard = app.buttons["account-setup.dismiss-keyboard"].firstMatch
        XCTAssertTrue(dismissKeyboard.waitForHittable(timeout: 5),
                      "manual IMAP setup has no reachable keyboard dismissal")
        dismissKeyboard.tap()
        for _ in 0..<8 where !connect.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(connect.isHittable, "Connect Account is covered after filling the IMAP form")
        connect.tap()
        let setupFailure = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Account verification failed.")
        ).firstMatch
        for attempt in 0..<120 where !app.staticTexts["Availability"].exists {
            if setupFailure.exists { XCTFail(setupFailure.label); return }
            if attempt == 30, connect.exists, connect.isEnabled {
                XCTFail("Connect Account remained enabled after tapping; setup did not start")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(app.staticTexts["Availability"].exists, app.debugDescription)
        let afterSetup = try await mailFixture("state")
        XCTAssertEqual(afterSetup.smtpDataCount, 1, "setup must submit exactly one verification DATA")
        if ProcessInfo.processInfo.environment["PLAINPOST_SETUP_ONLY"] == "1" {
            app.terminate()
            return
        }
        let passwordPrompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"]
        if passwordPrompt.waitForExistence(timeout: 5) { passwordPrompt.tap() }
        else if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }

        let availability = app.buttons["Alice, Availability"]
        XCTAssertTrue(waitForLaunch(availability, in: app),
                      "the cached message is not reachable after Direct account setup")
        availability.tap()
        let messageSubject = app.staticTexts["mailbox.reader.subject"]
        XCTAssertTrue(messageSubject.waitForExistence(timeout: 10))
        XCTAssertEqual(messageSubject.label, "Availability")
        XCTAssertEqual(app.staticTexts.matching(identifier: "mailbox.reader.subject").count, 1,
                       "the reader must show the subject once on iPhone")
        XCTAssertGreaterThanOrEqual(messageSubject.frame.minY, app.navigationBars.firstMatch.frame.maxY,
                                    "the subject must clear the navigation bar")
        app.buttons["conversation.toolbar.ai"].tap()
        let summary = app.descendants(matching: .any)["conversation.ai.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "conversation summary is missing")
        // Either a summary or the unavailable reason, depending on the host's on-device AI.
        XCTAssertFalse(summary.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "conversation summary has no text")
        summary.swipeDown(velocity: .fast)
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "the ✦ sheet closes")
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        let replyRecipient = app.textFields["To recipients"]
        let replySubject = app.textFields["Subject"]
        XCTAssertTrue(replyRecipient.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["compose.token.to.alice@example.com"].waitForExistence(timeout: 10))
        XCTAssertEqual(replySubject.value as? String, "Re: Availability")
        // Contacts authorization can interrupt the first tap as the composer
        // loads its local address book. Retry the editor tap after the alert.
        let replyBody = app.textViews.firstMatch
        XCTAssertTrue(replyBody.waitForExistence(timeout: 10))
        focusComposerBody(replyBody, in: app)
        replyBody.typeText("Standalone reply body")
        XCTAssertTrue((replyBody.value as? String)?.contains("Standalone reply body") == true,
                      "reply editor did not accept text after a tap in its blank area")
        let sendReply = app.buttons["compose.send"]
        XCTAssertTrue(sendReply.waitForEnabled(timeout: 10))
        sendReply.tap()
        XCTAssertTrue(app.buttons["compose.close"].waitForNonExistence(timeout: 15),
                      "the reply composer remained open after scheduling Send")
        XCTAssertTrue(app.descendants(matching: .any)["composer.send-status.sent"].waitForExistence(timeout: 60),
                      "direct-account reply did not reach durable Sent status")
        let replySendArrived = try await waitForSMTPData(2)
        XCTAssertTrue(replySendArrived, "reply did not submit exactly one SMTP DATA")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 10),
                      "reader Back did not return to the mailbox list")
        XCTAssertTrue(app.buttons["Alice, Availability"].waitForHittable(timeout: 10),
                      "message list is not visible after reading")
        let afterInjection = try await mailFixture("inject")
        XCTAssertTrue(afterInjection.injected)
        let injectedMessage = app.buttons["Sender, Incremental fixture"]
        if !injectedMessage.waitForExistence(timeout: 5) {
            pullToRefresh(in: app)
        }
        XCTAssertTrue(injectedMessage.waitForExistence(timeout: 30),
                      "the injected message did not arrive through Direct mail sync")
        app.buttons["mailbox.toolbar.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Incremental")
        let searchResult = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Incremental fixture")).firstMatch
        XCTAssertTrue(searchResult.waitForExistence(timeout: 30), "incremental message missing from local search")
        XCTAssertFalse(app.buttons["Alice, Availability"].exists)
        search.buttons["Clear text"].tap()
        XCTAssertTrue(searchResult.waitForNonExistence(timeout: 10),
                      "the previous result remained after clearing search")
        search.typeText("Post")
        XCTAssertEqual(search.value as? String, "Post")
        XCTAssertTrue(searchResult.waitForExistence(timeout: 30),
                      "Post sender address did not find the seeded message: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Check your search"].exists,
                       "Post search reached query validation instead of local results")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()

        let incremental = app.buttons["Sender, Incremental fixture"]
        incremental.swipeLeft()
        // The row's swipe action, not the toolbar's More menu.
        app.collectionViews.firstMatch.buttons["More"].tap()
        app.sheets["Incremental fixture"].buttons["Archive"].tap()
        let archived = try await waitForArchivedCount(1)
        XCTAssertTrue(archived, "archive committed after the Undo window")
        let afterArchive = try await mailFixture("state")
        XCTAssertEqual(afterArchive.deletedCount, 1, "archive must mark its copied original deleted")
        app.buttons["Alice, Availability"].tap()
        app.buttons["conversation.toolbar.remove"].tap()
        let deleteArrived = try await waitForDeletedCount(2)
        XCTAssertTrue(deleteArrived,
                      "explicit delete did not affect a second UID")
        XCTAssertTrue(app.buttons["Alice, Availability"].waitForNonExistence(timeout: 15),
                      "deleted message remained in the inbox")

        try composeFixtureMessage(subject: "Accepted fixture send", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["composer.send-status.sent"].waitForExistence(timeout: 60),
                      "accepted send did not reach durable Sent status")
        let acceptedSendArrived = try await waitForSMTPData(3)
        XCTAssertTrue(acceptedSendArrived)
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLaunch(app.navigationBars["Smart Inbox"], in: app))
        XCTAssertFalse(app.buttons["account.sign-in-with-apple"].exists)
        openSentMailbox(in: app)
        let acceptedRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Accepted fixture send")
        )
        XCTAssertTrue(acceptedRow.firstMatch.waitForExistence(timeout: 30),
                      "accepted send is missing from Sent after restart")
        XCTAssertEqual(acceptedRow.count, 1, "accepted send appears more than once in Sent")

        _ = try await mailFixture("ambiguous")
        try composeFixtureMessage(subject: "Uncertain fixture send", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["composer.send-status.uncertain"].waitForExistence(timeout: 60),
                      "ambiguous SMTP acknowledgement did not reach uncertain status")
        let uncertainSendArrived = try await waitForSMTPData(4)
        XCTAssertTrue(uncertainSendArrived)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["composer.send-status.uncertain"].waitForExistence(timeout: 30),
                      "uncertain send status was not restored from durable storage")
        openSentMailbox(in: app)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Accepted fixture send")
        ).count, 1)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Uncertain fixture send")
        ).count, 0, "uncertain SMTP outcome must not be shown as Sent")
        let afterUncertainRelaunch = try await mailFixture("state")
        XCTAssertEqual(afterUncertainRelaunch.smtpDataCount, 4, "uncertain send must not submit DATA again on relaunch")
        _ = try await mailFixture("offline")
        // Foregrounding a cached Direct account triggers its normal sync even
        // when the compact toolbar hides the manual Sync action.
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLaunch(app.navigationBars["Smart Inbox"], in: app))
        let retrySync = app.buttons["direct-mail.retry-sync"]
        XCTAssertTrue(retrySync.waitForExistence(timeout: 90),
                      "offline sync did not show a visible retry state")
        retrySync.tap()
        XCTAssertTrue(retrySync.waitForExistence(timeout: 90),
                      "retry did not return to a visible offline state")
        showMailboxes(in: app)
        // Activity is the last section of a list taller than the screen: scroll to it, then back.
        let mailboxList = app.collectionViews.firstMatch
        let syncFailure = app.descendants(matching: .any)["mailboxes.activity.host-sync-failure"]
        for _ in 0..<3 where !syncFailure.exists { mailboxList.swipeUp() }
        XCTAssertTrue(syncFailure.waitForExistence(timeout: 30),
                      "the Activity section shows the failed sync")
        let smartInboxRow = app.buttons["mailboxes.row.smartInbox"]
        for _ in 0..<3 where !smartInboxRow.isHittable { mailboxList.swipeDown() }
        smartInboxRow.tap()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].exists,
                      "retry left the selected Direct account")
        XCTAssertFalse(app.buttons["account.sign-in-with-apple"].exists)
        // A relaunch can restore the default mailbox. Open Sent explicitly
        // before checking that its accepted message is still cached offline.
        openSentMailbox(in: app)
        let cachedSent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Accepted fixture send")
        ).firstMatch
        XCTAssertTrue(cachedSent.waitForExistence(timeout: 10), "offline Sent row is unavailable")
        cachedSent.tap()
        XCTAssertTrue(app.staticTexts["Fixture body"].waitForExistence(timeout: 10),
                      "confirmed Sent message cannot be read from cache while offline")
        let afterOffline = try await mailFixture("state")
        XCTAssertEqual(afterOffline.smtpDataCount, 4)
    }

    private struct MailFixtureState: Decodable {
        let smtpDataCount: Int
        let imapLoginCount: Int
        let archivedCount: Int
        let deletedCount: Int
        let injected: Bool
        let offline: Bool
    }

    private func mailFixture(_ command: String) async throws -> MailFixtureState {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_MAIL_FIXTURE_CONTROL"])
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(command)"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(MailFixtureState.self, from: data)
    }

    private func waitForSMTPData(_ count: Int) async throws -> Bool {
        for _ in 0..<60 {
            let state = try await mailFixture("state")
            if state.smtpDataCount == count { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func waitForDeletedCount(_ count: Int) async throws -> Bool {
        for _ in 0..<30 {
            let state = try await mailFixture("state")
            if state.deletedCount == count { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func enterSetup(
        _ value: String, identifier: String, in app: XCUIApplication,
        secure: Bool = false, replacing: Bool = false
    ) {
        if app.keyboards.firstMatch.exists {
            let dismiss = app.buttons["account-setup.dismiss-keyboard"].firstMatch
            if dismiss.waitForHittable(timeout: 3) {
                dismiss.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                              "setup keyboard stayed open before \(identifier)")
                // SwiftUI Form may still be finishing its keyboard-driven
                // relayout after the keyboard disappears from accessibility.
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        // iOS Form lazily removes rows from accessibility as they scroll out.
        // Resolve a new element after every scroll and keyboard-driven layout.
        let fields = secure ? app.secureTextFields : app.textFields
        let query = fields.matching(identifier: identifier)
        let form = app.collectionViews.firstMatch
        guard form.waitForExistence(timeout: 5) else {
            XCTFail("account setup Form is missing")
            return
        }
        let fieldOrder = [
            "account-setup.display-name", "account-setup.email", "account-setup.username",
            "account-setup.imap-host", "account-setup.imap-port", "account-setup.imap-password",
            "account-setup.smtp-host", "account-setup.smtp-port", "account-setup.smtp-password",
        ]
        guard let targetIndex = fieldOrder.firstIndex(of: identifier) else {
            XCTFail("unknown account setup field \(identifier)")
            return
        }
        var missedFocusCount = 0
        for _ in 0..<20 {
            if let visible = query.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                visible.tap()
                let keyboard = app.keyboards.firstMatch
                if !keyboard.waitForExistence(timeout: 2) {
                    missedFocusCount += 1
                    if missedFocusCount < 4 {
                        Thread.sleep(forTimeInterval: 0.3)
                        continue
                    }
                    XCTFail("setup field \(identifier) did not receive keyboard focus")
                    return
                }
                let input = (replacing
                    ? String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)
                    : "") + value
                visible.typeText(input)
                return
            }
            let visibleIdentifiers = (
                app.textFields.allElementsBoundByIndex + app.secureTextFields.allElementsBoundByIndex
            ).filter(\.isHittable).map(\.identifier)
            let firstVisibleIndex = fieldOrder.firstIndex(where: visibleIdentifiers.contains)
            let pastTarget = firstVisibleIndex.map { $0 > targetIndex }
                ?? app.buttons["Connect Account"].isHittable
            let frame = form.frame
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : frame.maxY
            let bottom = min(frame.maxY, keyboardTop) - 20
            let top = frame.minY + 20
            guard bottom - top > 80 else {
                // SwiftUI can briefly report the keyboard as covering the
                // whole Form while focus moves to the next row. A Form swipe
                // still scrolls and avoids treating that transient geometry
                // as a setup failure.
                if pastTarget { form.swipeDown() } else { form.swipeUp() }
                continue
            }
            let startY = pastTarget ? top + 35 : bottom - 35
            let endY = pastTarget ? min(startY + 100, bottom) : max(startY - 100, top)
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (startY - frame.minY) / frame.height))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (endY - frame.minY) / frame.height))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let visibleIdentifiers = (
            app.textFields.allElementsBoundByIndex + app.secureTextFields.allElementsBoundByIndex
        ).map(\.identifier).filter { $0.hasPrefix("account-setup.") }
        XCTContext.runActivity(named: "Setup field \(identifier) unavailable") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
        XCTFail("setup field \(identifier) did not become tappable; visible setup identifiers: \(visibleIdentifiers); keyboard: \(app.keyboards.firstMatch.exists)")
    }

    private func enter(_ value: String, in field: XCUIElement, replacing: Bool = false) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let keyboard = XCUIApplication().keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2) {
            field.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "text field did not receive keyboard focus")
        }
        if replacing {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        }
        field.typeText(value)
    }

    private func composeFixtureMessage(subject: String, app: XCUIApplication) throws {
        if isPhone {
            app.buttons["mailbox.toolbar.compose"].tap()
            let recipient = app.textFields["To recipients"]
            XCTAssertTrue(recipient.waitForExistence(timeout: 5))
            // The shell asks for Contacts access on the To field's first focus, not when the
            // reply composer opens; answer it before typing, as focusComposerBody does.
            recipient.tap()
            answerContactsPrompt(waitingUpTo: 3)
            enter("receiver@example.test,", in: recipient)
            enter(subject, in: app.textFields["Subject"])
            enter("Fixture body", in: app.textViews.firstMatch)
            let send = app.buttons["compose.send"]
            XCTAssertTrue(send.waitForEnabled(timeout: 10))
            send.tap()
            return
        }
        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let recipient = app.textFields["To recipients"]
        if !recipient.waitForExistence(timeout: 5) {
            // A foreground sync can insert its retry banner while XCTest is
            // synthesizing the first toolbar tap. Retry after that layout
            // settles, while still failing if Compose remains unavailable.
            tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        }
        if !recipient.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Composer did not open after Compose") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
            }
        }
        enter("receiver@example.test", in: recipient)
        enter(subject, in: app.textFields["Subject"])
        enter("Fixture body", in: app.textViews.firstMatch)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForEnabled(timeout: 10))
        send.tap()
    }

    private func openSentMailbox(in app: XCUIApplication) {
        if isPhone {
            showMailboxes(in: app)
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "mailboxes.folder.", "Sent")).firstMatch.tap()
            return
        }
        let sent = app.descendants(matching: .any)["mailbox.sidebar.sent"].firstMatch
        if !sent.isHittable {
            let backToSidebar = app.navigationBars.buttons["BackButton"].firstMatch
            if backToSidebar.exists && backToSidebar.isHittable {
                backToSidebar.tap()
            } else {
                app.swipeRight()
            }
        }
        let sidebarList = app.collectionViews.firstMatch
        // Sidebar rows are lazy: Sent may not exist in the accessibility tree
        // until its section scrolls into view on a compact iPhone display.
        for _ in 0..<12 where !sent.isHittable {
            if sidebarList.exists { sidebarList.swipeUp() }
            else { app.swipeUp() }
        }
        if !sent.isHittable {
            XCTContext.runActivity(named: "Sent sidebar row is unavailable") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
            }
            XCTFail("Sent navigation is not reachable")
            return
        }
        sent.tap()
    }

    func testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount() throws {
        try XCTSkipUnless(isPhone, "The setup screen's Settings button is the iPhone shell's")
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MAILBOX_UI_ACCEPTANCE"] = "1"
        app.launch()

        XCTAssertTrue(waitForLaunch(app.staticTexts["Connect an account"], in: app))
        XCTAssertFalse(app.buttons["Account Security"].exists, "the account bar has no Account Security button")
        XCTAssertFalse(app.staticTexts["Sync Node required"].exists)
        app.buttons["account-setup.settings"].tap()
        app.buttons["settings.section.plainpostAccount"].tap()
        XCTAssertTrue(app.navigationBars["Plainpost Account"].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// Trusted devices are rows that open the device page; Revoke and Delete are plain
    /// buttons that confirm, then show the Apple sheet. No Apple button sits on the pages.
    func testPlainpostAccountProtectedActionsConfirmBeforeTheAppleSheet() throws {
        try XCTSkipUnless(isPhone, "This regression exercises the iPhone shell")
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_DEBUG_ACCOUNT_SECURITY"] = "1"
        app.launch()
        XCTAssertTrue(waitForLaunch(app.navigationBars["Smart Inbox"], in: app))
        showMailboxes(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        app.buttons["settings.section.plainpostAccount"].tap()
        XCTAssertTrue(app.navigationBars["Plainpost Account"].waitForExistence(timeout: 10), app.debugDescription)

        let appleButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apple"))
        let thisPhone = app.buttons["account-security.device.90000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(thisPhone.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(thisPhone.label.contains("This iPhone"), thisPhone.label)
        XCTAssertEqual(appleButtons.count, 0, "no inline Apple buttons on the page")

        app.buttons["account-security.device.90000000-0000-4000-8000-000000000002"].tap()
        XCTAssertTrue(app.textFields["account-security.device-detail.name"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Suspend blocks this device from your account. Revoke removes it permanently."].exists)
        XCTAssertEqual(appleButtons.count, 0, "no inline Apple buttons on the device page")
        app.buttons["account-security.device-detail.revoke"].tap()
        let proceed = app.buttons["Continue to Apple Confirmation"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5), app.debugDescription)
        proceed.tap()
        XCTAssertTrue(app.buttons["account-security.authorization.apple"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Revoke trusted device"].exists)
        app.buttons["account-security.authorization.cancel"].tap()
        XCTAssertTrue(app.buttons["account-security.authorization.apple"].waitForNonExistence(timeout: 5))

        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        let delete = app.buttons["account-security.delete-account"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), app.debugDescription)
        delete.tap()
        XCTAssertTrue(proceed.waitForExistence(timeout: 5), app.debugDescription)
        proceed.tap()
        XCTAssertTrue(app.staticTexts["Delete Plainpost account"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["account-security.authorization.cancel"].tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
    }

    // Retain the historical failure identifiers, with the phone's current
    // Mailboxes → inbox → conversation contract rather than desktop toolbar labels.
    /// Both Sync Node accounts are in one list; each one's actions reach its own account.
    func testNavigationBarActionsReachEachSyncNodeAccount() throws {
        try XCTSkipUnless(isPhone, "This regression exercises the iPhone shell")
        let app = launchPhoneMultiAccountFixture()
        for (account, subject) in [("ada@example.test", "Analytical engine notes"), ("grace@example.test", "Compiler review")] {
            XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 15))
            let row = mailRow(subject, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].isHittable)
            row.tap()
            XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
            for identifier in ["conversation.toolbar.remove", "conversation.toolbar.reply", "mailbox.toolbar.compose"] {
                XCTAssertTrue(app.buttons[identifier].isHittable, "\(identifier) must be reachable for \(account)")
            }
            attachScreenshot(of: app, named: "Phone conversation actions for \(account)")
            let removal = app.buttons["conversation.toolbar.remove"]
            XCTAssertTrue(["Archive", "Delete"].contains(removal.label))
            let mutation = removal.label == "Archive" ? "archive" : "delete"
            removal.tap()
            XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("\(mutation) \(account)", timeout: 15),
                          "The removal action must reach the displayed account's runtime")
            XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].waitForExistence(timeout: 10))
            app.buttons["mailbox.toolbar.compose"].tap()
            XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10))
            app.buttons["compose.close"].tap()
        }
    }

    /// A reply to the second Sync Node account's message goes out from that account.
    func testAReplyToTheSecondSyncNodeAccountSendsFromIt() throws {
        try XCTSkipUnless(isPhone, "This regression exercises the iPhone shell")
        let app = launchPhoneMultiAccountFixture()
        let grace = mailRow("Compiler review", in: app)
        XCTAssertTrue(grace.waitForExistence(timeout: 15))
        grace.tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10))
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        focusComposerBody(body, in: app)
        body.typeText("Reply from grace")
        XCTAssertTrue(app.buttons["compose.send"].isHittable)
        app.buttons["compose.send"].tap()
        XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("send grace@example.test", timeout: 30),
                      "The reply goes out from grace's account once Undo ends")
    }

    func testNotificationSettingsUseDeviceCopyOnCompactIPhone() throws {
        try XCTSkipUnless(isPhone, "This regression exercises the iPhone shell")
        let app = launchPhoneMultiAccountFixture()
        showMailboxes(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        app.buttons["settings.section.smartInbox"].tap()
        let mode = app.descendants(matching: .any)["settings.smartInbox.mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThanOrEqual(mode.frame.maxX, app.windows.firstMatch.frame.maxX)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        app.buttons["settings.section.notifications"].tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["macOS notifications"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "macOS notification access")).firstMatch.exists)
    }

    func testReplyComposerBlankBodyTapAcceptsTyping() throws {
        try XCTSkipUnless(isPhone, "This regression exercises the iPhone shell")
        let app = launchPhoneMultiAccountFixture()
        mailRow("Analytical engine notes", in: app).tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        focusComposerBody(body, in: app)
        body.typeText("A typed reply")
        XCTAssertTrue((body.value as? String ?? "").contains("A typed reply"))
        XCTAssertTrue(app.buttons["compose.close"].isHittable)
        XCTAssertTrue(app.buttons["compose.send"].isHittable)
    }

    private func launchPhoneMultiAccountFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()
        XCTAssertTrue(waitForLaunch(app.navigationBars["Smart Inbox"], in: app))
        XCTAssertTrue(mailRow("Analytical engine notes", in: app).waitForExistence(timeout: 15))
        return app
    }

    func testMailboxLeadingSwipeMarksMessageRead() throws {
        try requireSplitViewRoot()
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()

        let message = app.staticTexts["Analytical engine notes"]
        XCTAssertTrue(waitForLaunch(message, in: app))
        message.swipeRight()
        let read = app.buttons["envelope.open"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), app.debugDescription)
        read.tap()
        let mutation = app.staticTexts["debug.node-mutation.last"]
        XCTAssertTrue(mutation.waitForLabel("markRead ada@example.test", timeout: 10))
    }

    /// The fixture account is Gmail: its trailing swipe archives.
    func testMailboxTrailingSwipeArchivesMessage() throws {
        try requireSplitViewRoot()
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()

        let message = app.staticTexts["Analytical engine notes"]
        XCTAssertTrue(waitForLaunch(message, in: app))
        message.swipeLeft()
        let archive = app.buttons["Archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5), app.debugDescription)
        archive.tap()
        let mutation = app.staticTexts["debug.node-mutation.last"]
        XCTAssertTrue(mutation.waitForLabel("archive ada@example.test", timeout: 10))
    }

    /// Runs on iPhone and iPad: with two Sync Node accounts in the list, the inbox's
    /// Compose opens the composer.
    func testMultiAccountInboxComposeIsReachable() throws {
        try requireSplitViewRoot()
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()

        XCTAssertTrue(waitForLaunch(app.staticTexts["Analytical engine notes"], in: app))
        XCTAssertFalse(app.buttons["Close composer"].exists)
        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        XCTAssertTrue(app.buttons["Close composer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testSingleAccountChromeLeavesNavigationBarAndComposerReachable() throws {
        try requireSplitViewRoot()
        let app = launchSingleAccount()

        XCTAssertFalse(app.descendants(matching: .any)["mail-account.header"].exists)
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Account Security"].exists, "the account bar has no Account Security button")
        XCTAssertFalse(notificationStatus(in: app).exists, "the notification menu moved to Settings")
        assertNavigationBarReachable(in: app, clearOf: [])
        attachScreenshot(of: app, named: "Single account inbox")

        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let close = app.buttons["Close composer"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save Draft"].exists)
        XCTAssertFalse(app.staticTexts["New local draft"].exists)
        for control in [close, app.buttons["Send"]] {
            XCTAssertTrue(control.exists, "\(control) is missing")
        }
        XCTAssertTrue(close.isHittable, "Close composer is not hittable")
        // Without the keyboard the composer reaches the bottom of the screen
        // rather than floating above it with the mail showing through a gap.
        let window = app.windows.firstMatch
        if !app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(
                window.frame.maxY - app.buttons["Send"].frame.maxY, 70,
                "Send \(app.buttons["Send"].frame) floats far above the bottom of \(window.frame)"
            )
        }
        attachScreenshot(of: app, named: "Single account composer")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "Close composer did not close it")
    }

    func testUnsentComposerCloseOffersCancelAndDelete() throws {
        try requireSplitViewRoot()
        let app = launchSingleAccount()
        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let subject = app.textFields["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        subject.typeText("An unfinished note")

        let close = app.buttons["Close composer"]
        close.tap()
        XCTAssertTrue(app.buttons["Keep Draft"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(subject.value as? String, "An unfinished note")

        close.tap()
        let delete = app.buttons["Delete Draft"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
    }

    func testPopulatedLocalPostSearchFindsSeededMail() throws {
        try requireSplitViewRoot()
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_LOCAL_SEARCH_UI_ACCEPTANCE"] = UUID().uuidString
        app.launch()

        let seededMail = app.staticTexts["Parcel update"]
        XCTAssertTrue(waitForLaunch(seededMail, in: app),
                      "the populated Direct fixture did not open its cached inbox")
        tapNavigationBarButton("mailbox.toolbar.command-center", in: app)
        let searchCommand = app.buttons["command-center.search_mail"]
        XCTAssertTrue(searchCommand.waitForExistence(timeout: 10))
        searchCommand.tap()
        let search = app.textFields["Search emails"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(seededMail.waitForNonExistence(timeout: 10))
        enter("Post", in: search)

        XCTAssertEqual(search.value as? String, "Post")
        XCTAssertTrue(seededMail.waitForExistence(timeout: 30),
                      "Post search did not return the seeded sender: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Check your search"].exists,
                       "Post search reached query validation instead of local results")
        attachScreenshot(of: app, named: "Populated local Post search")
    }

    func testDirectAccountSettingsShowsKeepOnDeviceOnCompactIPhone() throws {
        try XCTSkipUnless(isPhone, "This settings path is retargeted to the iPhone shell")
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_LOCAL_SEARCH_UI_ACCEPTANCE"] = UUID().uuidString
        app.launch()

        XCTAssertTrue(waitForLaunch(app.navigationBars["Smart Inbox"], in: app))
        showMailboxes(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.account.'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), app.debugDescription)
        account.tap()
        // The picker replaces the old history button and status line.
        let keepOnDevice = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Keep on this device")).firstMatch
        XCTAssertTrue(keepOnDevice.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !keepOnDevice.isHittable { app.swipeUp() }
        attachScreenshot(of: app, named: "Direct account settings")
        XCTAssertTrue(keepOnDevice.isHittable, "Keep on this device must be visible on the account page")
        XCTAssertFalse(app.staticTexts["Account ID"].exists, "the account page shows no raw account ID")
    }

    /// While the body is being typed, Close and Send stay above the
    /// software keyboard and can be tapped without ending editing first.
    /// Runs with per-mailbox notification policy rows, the usual Sync Node
    /// case, which once put a panel over the composer.
    func testComposerActionsStayAboveTheKeyboardWhileTyping() throws {
        try requireSplitViewRoot()
        try assertComposerActionsStayAboveTheKeyboard(launchSingleAccount(Self.notificationPolicyRows))
    }

    func testComposerBlankBodyTapAcceptsTyping() throws {
        try requireSplitViewRoot()
        let app = launchSingleAccount()
        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.tap()
        body.typeText("Typed into blank body")
        XCTAssertTrue((body.value as? String)?.contains("Typed into blank body") == true,
                      "the full composer body should accept a tap below its placeholder")
    }

    private func focusComposerBody(_ body: XCUIElement, in app: XCUIApplication) {
        body.tap()
        answerContactsPrompt(waitingUpTo: 0)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            // The system may have consumed the first tap while granting
            // Contacts access. A second blank-area tap must focus the editor.
            body.tap()
        }
    }

    /// Grants the Contacts prompt (and iOS 18+'s follow-up share sheet) if it is showing, or
    /// appears within `timeout`. This fixture runs only on a fresh Simulator with synthetic contacts.
    private func answerContactsPrompt(waitingUpTo timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let contactsAlert = springboard.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Contacts")
        ).firstMatch
        if contactsAlert.exists || (timeout > 0 && contactsAlert.waitForExistence(timeout: timeout)) {
            let continueButton = contactsAlert.buttons["Continue"]
            XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
            continueButton.tap()
        }
        // iOS 18+ can follow the alert with a second SpringBoard sheet
        // asking which contacts to share. This fixture runs only on a fresh
        // Simulator with synthetic contacts; authorize them for autocomplete.
        let shareAll = springboard.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Share All")
        ).firstMatch
        if shareAll.waitForExistence(timeout: 3) {
            shareAll.tap()
        }
    }

    /// The same with a device-approval prompt taking space above the mail, as
    /// on a shorter iPhone: the body editor gives way, not the Send bar.
    func testComposerActionsStayAboveTheKeyboardWithLessRoom() throws {
        try requireSplitViewRoot()
        let app = launchSingleAccount(Self.notificationPolicyRows.merging(["PLAINPOST_DEBUG_PENDING_DEVICE_APPROVAL": "1"]) { $1 })
        XCTAssertTrue(app.buttons["account.pending-device.review"].waitForExistence(timeout: 10))
        try assertComposerActionsStayAboveTheKeyboard(app)
    }

    private func assertComposerActionsStayAboveTheKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let lastMutation = app.staticTexts["debug.node-mutation.last"]

        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("someone@example.test")
        let subject = app.textFields["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        subject.tap()
        subject.typeText("Typed with the keyboard up")
        let keyboard = try requireSoftwareKeyboard(in: app)
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        body.typeText("Still typing")

        let close = app.buttons["Close composer"]
        let send = app.buttons["Send"]
        XCTAssertTrue(close.waitForEnabled(timeout: 10))
        XCTAssertTrue(keyboard.exists, "the keyboard went away while typing", file: file, line: line)
        let policyPanel = mailboxPolicyPanel(in: app)
        for control in [close, send] {
            XCTAssertLessThanOrEqual(
                control.frame.maxY, keyboard.frame.minY,
                "\(control.label) \(control.frame) lies under the keyboard \(keyboard.frame)",
                file: file, line: line
            )
            XCTAssertTrue(control.isHittable, "\(control.label) is not hittable while typing", file: file, line: line)
            assertClear(control, of: [policyPanel], file: file, line: line)
        }
        attachScreenshot(of: app, named: "Composer while typing")
        close.tap()
        let keepDraft = app.buttons["Keep Draft"]
        XCTAssertTrue(keepDraft.waitForExistence(timeout: 10))
        keepDraft.tap()
        XCTAssertTrue(lastMutation.waitForLabel("saveDraft ada@example.test", timeout: 10), "last mutation: \(lastMutation.labelIfExists)", file: file, line: line)
    }

    /// The failed-send snackbar's Open Draft is not covered by other chrome.
    func testFailedSendSnackbarOpenDraftIsReachable() throws {
        try requireSplitViewRoot()
        let app = launchSingleAccount(Self.notificationPolicyRows.merging(["PLAINPOST_DEBUG_NODE_FAILING_SEND": "1"]) { $1 })
        let lastMutation = app.staticTexts["debug.node-mutation.last"]

        tapNavigationBarButton("mailbox.toolbar.compose", in: app)
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("someone@example.test")
        let subject = app.textFields["Subject"]
        subject.tap()
        subject.typeText("Rejected")
        let body = app.textViews.firstMatch
        body.tap()
        body.typeText("This send fails")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForEnabled(timeout: 10))
        XCTAssertTrue(send.isHittable, "Send is not hittable while typing")
        assertClear(send, of: [mailboxPolicyPanel(in: app)])
        send.tap()
        XCTAssertTrue(lastMutation.waitForLabel("send rejected ada@example.test", timeout: 30), "last mutation: \(lastMutation.labelIfExists)")

        let openDraft = app.buttons["Open Draft"]
        XCTAssertTrue(openDraft.waitForExistence(timeout: 10))
        XCTAssertTrue(openDraft.isHittable, "Open Draft is not hittable")
        assertClear(openDraft, of: [mailboxPolicyPanel(in: app)])
        attachScreenshot(of: app, named: "Failed send snackbar")
        openDraft.tap()
        XCTAssertTrue(app.buttons["Close composer"].waitForExistence(timeout: 10), "Open Draft did not reopen the composer")
    }

    /// Per-mailbox notification detail lives in a sheet opened from
    /// Settings ▸ Notifications, never in a panel over the mail.
    func testPerMailboxNotificationDetailOpensFromNotificationSettings() throws {
        let app = launchSingleAccount(Self.notificationPolicyRows)
        let panel = mailboxPolicyPanel(in: app)
        XCTAssertFalse(panel.exists, "the per-mailbox panel is shown over the mail")
        try openSettingsSection("notifications", in: app)

        let status = notificationStatus(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        let perMailbox = app.buttons["notifications.per-mailbox-detail"]
        // The rows load after the mail opens; the page offers them once loaded.
        XCTAssertTrue(perMailbox.waitForExistence(timeout: 20), "Notifications offers no per-mailbox settings")
        perMailbox.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the per-mailbox sheet did not open")
        XCTAssertTrue(app.staticTexts["ada@example.test"].waitForExistence(timeout: 5), "the sheet lacks the mailbox row")
        attachScreenshot(of: app, named: "Per-mailbox notification detail")
        let done = app.buttons["notifications.mailbox-policy.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "the per-mailbox sheet did not close")
        XCTAssertTrue(app.navigationBars["Notifications"].exists)
    }

    /// At accessibility text sizes (AX3 and the largest, AX5) the
    /// notification detail in Settings ▸ Notifications fits the screen and
    /// works, and the mail carries no account-bar controls.
    func testNotificationSettingsFitAtAccessibilityTextSizes() throws {
        for (name, category) in [("AX3", "UICTContentSizeCategoryAccessibilityXL"), ("AX5", "UICTContentSizeCategoryAccessibilityXXXL")] {
            let app = launchSingleAccount(
                Self.notificationPolicyRows,
                arguments: ["-UIPreferredContentSizeCategoryName", category]
            )
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Account Security"].exists, "the account bar has no Account Security button at \(name)")
            XCTAssertFalse(notificationStatus(in: app).exists, "the notification menu moved to Settings at \(name)")
            try openSettingsSection("notifications", in: app)
            let status = notificationStatus(in: app)
            for _ in 0..<6 where !(status.exists && status.isHittable) { app.swipeUp() }
            XCTAssertTrue(status.waitForExistence(timeout: 10), "the notification detail is missing at \(name)")
            attachScreenshot(of: app, named: "Notification settings at \(name)")
            XCTAssertTrue(status.isHittable, "the notification detail is not hittable at \(name)")
            XCTAssertGreaterThanOrEqual(status.frame.minX, window.frame.minX, "\(status.frame) starts off screen at \(name)")
            XCTAssertLessThanOrEqual(status.frame.maxX, window.frame.maxX, "\(status.frame) ends off screen at \(name)")
            app.terminate()
        }
    }

    /// The pending-device review prompt sits in the layout with the other
    /// account chrome, not over the navigation bar.
    func testPendingDeviceApprovalPromptLeavesNavigationBarReachable() {
        let app = launchSingleAccount(["PLAINPOST_DEBUG_PENDING_DEVICE_APPROVAL": "1"])

        let review = app.buttons["account.pending-device.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isHittable, "the pending-device review is not hittable")
        XCTAssertFalse(app.buttons["Account Security"].exists, "the account bar has no Account Security button")
        assertNavigationBarReachable(in: app, clearOf: [review])
        attachScreenshot(of: app, named: "Pending device approval")
    }

    /// The device-code confirmation replaces the pending pill in the same place.
    func testDeviceApprovalCodePromptLeavesNavigationBarReachable() {
        let app = launchSingleAccount(["PLAINPOST_DEBUG_DEVICE_APPROVAL_CODE": "1"])

        let code = app.staticTexts["Confirm device code 123456"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Account Security"].exists, "the account bar has no Account Security button")
        assertNavigationBarReachable(in: app, clearOf: [code])
        attachScreenshot(of: app, named: "Device approval code")
    }

    /// Makes the debug Node's account carry a Sync Node notification
    /// producer, so per-mailbox notification policy rows exist.
    private static let notificationPolicyRows = ["PLAINPOST_DEBUG_NOTIFICATION_POLICY_ROWS": "1"]

    private func launchSingleAccount(_ environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_DEBUG_NODE_SINGLE_ACCOUNT"] = "1"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        XCTAssertTrue(waitForLaunch(isPhone ? app.navigationBars["Smart Inbox"] : app.staticTexts["Analytical engine notes"], in: app))
        return app
    }

    private func mailboxPolicyPanel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["notifications.mailbox-policy"].firstMatch
    }

    /// The software keyboard, or a skip: with a hardware keyboard connected
    /// the simulator shows none, and keyboard checks would pass vacuously.
    private func requireSoftwareKeyboard(in app: XCUIApplication) throws -> XCUIElement {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            throw XCTSkip("No software keyboard is shown (a hardware keyboard is connected), so keyboard overlap cannot be measured.")
        }
        return keyboard
    }

    private func notificationStatus(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["notifications.registration-status"].firstMatch
    }

    /// Opens a Settings section through the iPhone shell: Mailboxes ▸ Settings ▸ section.
    private func openSettingsSection(_ raw: String, in app: XCUIApplication) throws {
        try XCTSkipUnless(isPhone, "This Settings path is the iPhone shell's")
        showMailboxes(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let section = app.buttons["settings.section.\(raw)"]
        for _ in 0..<4 where !section.isHittable { app.swipeUp() }
        section.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Fails when `element` overlaps any of `covers` that exist on screen.
    private func assertClear(_ element: XCUIElement, of covers: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        for cover in covers where cover.exists {
            XCTAssertFalse(
                frame.intersects(cover.frame),
                "\(element.identifier.isEmpty ? element.label : element.identifier) \(frame) overlaps \(cover.identifier.isEmpty ? cover.label : cover.identifier) \(cover.frame)",
                file: file, line: line
            )
        }
    }

    /// Every visible navigation-bar control is hittable and clear of `covers`.
    private func assertNavigationBarReachable(in app: XCUIApplication, clearOf covers: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        XCTAssertFalse(bars.isEmpty, "no navigation bar", file: file, line: line)
        var checked = 0
        for bar in bars {
            assertClear(bar, of: covers, file: file, line: line)
            for button in bar.buttons.allElementsBoundByIndex where button.exists && !button.frame.isEmpty {
                XCTAssertTrue(button.isHittable, "navigation-bar button \(button.identifier) \(button.label) \(button.frame) is not hittable", file: file, line: line)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no navigation-bar buttons were found", file: file, line: line)
    }

    /// Taps a navigation-bar button once it is hittable. XCUITest taps at the button's hit
    /// point, so a covered button would pass the tap to whatever covers it; callers therefore
    /// also assert the action's effect.
    private func tapNavigationBarButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.navigationBars.buttons[identifier].firstMatch
        if !button.exists || !button.isHittable {
            // iPhone may move trailing toolbar actions into its system More
            // menu without keeping navigation-bar elements discoverable.
            let more = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            if more.exists && more.isHittable {
                more.tap()
                let menuAction = app.buttons[identifier].firstMatch
                XCTAssertTrue(menuAction.waitForHittable(timeout: 5),
                              "\(identifier) is missing from the toolbar More menu")
                menuAction.tap()
                return
            }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), "navigation action \(identifier) is missing")
        XCTAssertTrue(button.waitForEnabled(timeout: 10), "\(identifier) is disabled")
        for _ in 0..<40 where !button.isHittable {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !button.isHittable {
            XCTContext.runActivity(named: "Navigation action \(identifier) was not hittable") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
            }
        }
        XCTAssertTrue(button.isHittable, "\(identifier) is not hittable")
        button.tap()
    }
}

private extension XCUIElement {
    var labelIfExists: String {
        exists ? label : "<none>"
    }

    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func waitForDisabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, !isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, self.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
