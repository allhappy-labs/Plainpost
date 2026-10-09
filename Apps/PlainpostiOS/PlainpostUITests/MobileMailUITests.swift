import XCTest

/// The iPhone shell (Mailboxes → mailbox → conversation) on the realistic fixture corpus and,
/// for actions that must reach a backend, the debug Sync Node fixture.
@MainActor
final class MobileMailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The mobile shell is iPhone-only")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    func launchRealistic(arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["PLAINPOST_REALISTIC_MAIL_UI_ACCEPTANCE"] = UUID().uuidString
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 120), app.debugDescription)
        return app
    }

    func launchNode(_ environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_DEBUG_NODE_SINGLE_ACCOUNT"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 120), app.debugDescription)
        return app
    }

    func row(_ labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    func back(in app: XCUIApplication) {
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func openMaria(in app: XCUIApplication) {
        let maria = row("Maria Chen, Re: Quarterly planning", in: app)
        XCTAssertTrue(maria.waitForExistence(timeout: 10), app.debugDescription)
        maria.tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
    }

    /// The realistic fixture answering with the deterministic local AI, since simulators have
    /// no on-device model.
    func launchRealisticWithAI(environment: [String: String] = [:]) -> XCUIApplication {
        var merged = environment
        merged["PLAINPOST_UI_TEST_AI_PROVIDER"] = "deterministic"
        return launchRealistic(environment: merged)
    }

    /// Taps ✦ and waits for the pane's summary section.
    @discardableResult
    func openConversationAI(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["conversation.toolbar.ai"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        button.tap()
        let summary = app.descendants(matching: .any)["conversation.ai.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        return summary
    }

    // MARK: Milestone 1

    func testLaunchOpensSmartInboxAndBackShowsMailboxes() {
        let app = launchRealistic()
        XCTAssertTrue(row("Maria Chen, Re: Quarterly planning", in: app).waitForExistence(timeout: 5), app.debugDescription)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        for id in ["smartInbox", "allInboxes", "unread", "approvals", "settings"] {
            XCTAssertTrue(app.buttons["mailboxes.row.\(id)"].exists, "missing Mailboxes row \(id)")
        }
        XCTAssertFalse(app.buttons["mailbox.toolbar.command-center"].exists)
        XCTAssertFalse(app.staticTexts["Plainpost"].exists, "no sidebar title on iPhone")
        XCTAssertFalse(app.buttons["mailboxes.account-switcher"].exists, "Mailboxes has no account switcher; Settings switches accounts")
    }

    func testConversationBackWalksOneLevelAtATime() {
        let app = launchRealistic()
        openMaria(in: app)
        XCTAssertTrue(app.navigationBars["3 Messages"].exists)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Mailboxes"].exists, "one Back must not reach Mailboxes")
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
    }

    func testConversationShowsNewestFirstWithItsActions() {
        let app = launchRealistic()
        openMaria(in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Good catch — updated")).firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["conversation.earlier"].label, "2 earlier messages")
        XCTAssertEqual(app.buttons["conversation.toolbar.remove"].label, "Delete", "a non-Gmail account deletes")
        XCTAssertTrue(app.buttons["conversation.toolbar.reply"].exists)
        XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].exists)
        XCTAssertTrue(app.buttons["conversation.toolbar.ai"].exists)
    }

    /// A sign-in code mail offers its code above the conversation; Copy confirms, then resets.
    func testVerificationCodeBannerCopiesTheCode() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_VERIFICATION_CODE_MAIL": "1"])
        let codeMail = row("GitHub, [GitHub] Please verify your device", in: app)
        XCTAssertTrue(codeMail.waitForExistence(timeout: 10), app.debugDescription)
        codeMail.tap()
        let banner = app.descendants(matching: .any)["conversation.verificationCode"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(banner.label, "Verification code 482913")
        let copy = app.buttons["conversation.verificationCode.copy"]
        XCTAssertEqual(copy.label, "Copy")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "verification-code-banner"
        before.lifetime = .keepAlways
        add(before)

        copy.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { copy.label == "Copied" }, app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "verification-code-copied"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertTrue(waitUntil(timeout: 5) { copy.label == "Copy" }, app.debugDescription)

        back(in: app)
        openMaria(in: app)
        XCTAssertFalse(banner.exists, "a conversation without a code shows no banner")
    }

    func testConversationAIShowsTheReasonWhenAIIsUnavailable() {
        let app = launchRealistic(environment: ["PLAINPOST_AI_AVAILABILITY_UI_ACCEPTANCE": "model-not-ready"])
        openMaria(in: app)
        let summary = openConversationAI(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { summary.label.contains("Apple’s on-device model isn’t ready") },
                      "expected the model-not-ready reason, got: \(summary.label)")
    }

    /// Draft reply is disabled from the start when AI is unavailable.
    func testDraftReplyIsDisabledWhenAIIsUnavailable() {
        let app = launchRealistic(environment: ["PLAINPOST_AI_AVAILABILITY_UI_ACCEPTANCE": "model-not-ready"])
        openMaria(in: app)
        openConversationAI(in: app)
        let draft = app.buttons["conversation.ai.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertFalse(draft.isEnabled)
    }

    func testConversationAIOpensWithTheSummary() {
        let app = launchRealisticWithAI()
        openMaria(in: app)
        let summary = openConversationAI(in: app)
        XCTAssertTrue(waitUntil(timeout: 30) { summary.label.contains("Alice asked about availability") },
                      "summary: \(summary.label)")
        XCTAssertEqual(app.staticTexts["conversation.ai.locality"].label, "On-device 🔒")
    }

    func testDraftReplyPreviewsAndEditInComposeOpensIt() {
        let app = launchRealisticWithAI()
        openMaria(in: app)
        openConversationAI(in: app)
        app.buttons["conversation.ai.draft"].tap()
        app.buttons["conversation.ai.tone.friendly"].tap()
        let preview = app.descendants(matching: .any)["conversation.ai.draft.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(preview.label.contains("Tuesday works for me"), preview.label)
        app.buttons["conversation.ai.draft.edit"].tap()
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { (body.value as? String)?.contains("Tuesday works for me") == true },
                      "composer body: \(body.value ?? "")")
    }

    func testTranslateClosesTheSheetAndShowOriginalRestores() {
        let app = launchRealisticWithAI()
        openMaria(in: app)
        let summary = openConversationAI(in: app)
        app.buttons["conversation.ai.translate"].tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "Translate closes the sheet")
        let pill = app.descendants(matching: .any)["conversation.translation-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), app.debugDescription)
        let showOriginal = app.buttons["conversation.translation-pill.show-original"]
        XCTAssertTrue(showOriginal.waitForExistence(timeout: 30), app.debugDescription)
        showOriginal.tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 10))
    }

    func testAskAboutThisConversationAnswersInTheSheet() {
        let app = launchRealisticWithAI()
        openMaria(in: app)
        openConversationAI(in: app)
        let field = app.textFields["conversation.ai.ask-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText("When is the meeting?\n")
        XCTAssertTrue(app.buttons["conversation.ai.back"].waitForExistence(timeout: 10), "asking opens the Ask route")
        let turn = app.descendants(matching: .any)["conversation.ai.turn"]
        XCTAssertTrue(turn.waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["conversation.ai.back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation.ai.summary"].waitForExistence(timeout: 10))
    }

    func testReplyMenuOffersOnlyReplyReplyAllAndForward() {
        let app = launchRealistic()
        openMaria(in: app)
        app.buttons["conversation.toolbar.reply"].tap()
        XCTAssertTrue(app.buttons["conversation.reply-menu.reply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conversation.reply-menu.reply-all"].exists)
        XCTAssertTrue(app.buttons["conversation.reply-menu.forward"].exists)
        XCTAssertFalse(app.buttons["conversation.reply-menu.draft-with-ai"].exists)
        XCTAssertFalse(app.buttons["conversation.reply-menu.translate"].exists)
    }

    func testReplyOpensTheComposerSheet() {
        let app = launchRealistic()
        openMaria(in: app)
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10), app.debugDescription)
        // The To field holds a token per recipient; its text field holds only what's being typed.
        let mariaToken = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
            "compose.token.to.", "maria.chen@northwind.example"
        )).firstMatch
        XCTAssertTrue(mariaToken.waitForExistence(timeout: 5), "Reply must address Maria: \(app.debugDescription)")
        let subject = app.textFields["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5), app.debugDescription)
        let subjectValue = subject.value as? String ?? ""
        XCTAssertTrue(subjectValue.hasPrefix("Re: Quarterly planning"), "Reply subject must start with Re:, got: \(subjectValue)")
    }

    func testComposeIsReachableFromEveryLevel() {
        let app = launchRealistic()
        XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].isHittable)
        openMaria(in: app)
        XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].isHittable)
        back(in: app)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["mailbox.toolbar.compose"].waitForExistence(timeout: 5))
        app.buttons["mailbox.toolbar.compose"].tap()
        XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10))
    }

    func testSettingsRowAlwaysOpensTheSettingsList() {
        let app = launchRealistic()
        back(in: app)
        for _ in 0..<2 {
            app.buttons["mailboxes.row.settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.account.'")).firstMatch.exists)
            XCTAssertFalse(app.buttons["mailboxes.account-switcher"].exists, "account switching left Settings")
            app.buttons["settings.section.smartInbox"].tap()
            XCTAssertTrue(app.navigationBars["Smart Inbox & AI"].waitForExistence(timeout: 5))
            back(in: app)
            back(in: app)
            XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        }
    }

    /// Settings lists every account; each row opens that account's page without switching,
    /// and Mailboxes keeps both accounts.
    func testSettingsOpensEachAccountsPageWithoutSwitching() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_SECOND_LOCAL_ACCOUNT": "1"])
        back(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let work = app.buttons["settings.account.realistic-fixture-work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["settings.account.realistic-fixture"].exists, app.debugDescription)
        work.tap()
        XCTAssertTrue(app.navigationBars["work@example.test"].waitForExistence(timeout: 10), app.debugDescription)
        back(in: app)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mailboxes.account.realistic-fixture"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["mailboxes.account.realistic-fixture-work"].exists, app.debugDescription)
    }

    /// All Inboxes mixes every account's mail, and says which account each message came to.
    func testAllInboxesShowsMailFromEveryAccount() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_SECOND_LOCAL_ACCOUNT": "1"])
        back(in: app)
        XCTAssertFalse(app.buttons["mailboxes.account-switcher"].exists)
        app.buttons["mailboxes.row.allInboxes"].tap()
        XCTAssertTrue(row("Maria Chen, Re: Quarterly planning", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let welcome = row("Work IT, Welcome to the work account", in: app)
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(welcome.label.hasSuffix("account work"), welcome.label)
    }

    /// One account's Inbox shows only that account's mail.
    func testAnAccountsInboxShowsOnlyThatAccount() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_SECOND_LOCAL_ACCOUNT": "1"])
        back(in: app)
        let workInbox = app.buttons["mailboxes.folder.realistic-fixture-work|INBOX"]
        XCTAssertTrue(workInbox.waitForExistence(timeout: 10), app.debugDescription)
        workInbox.tap()
        XCTAssertTrue(row("Work IT, Welcome to the work account", in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(row("Maria Chen, Re: Quarterly planning", in: app).exists)
    }

    /// With two accounts, New Message offers both as From.
    func testComposeOffersEveryAccountAsFrom() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_SECOND_LOCAL_ACCOUNT": "1"])
        back(in: app)
        app.buttons["mailbox.toolbar.compose"].tap()
        XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10))
        let ccBcc = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cc/Bcc, From: '")).firstMatch
        XCTAssertTrue(ccBcc.waitForExistence(timeout: 5), app.debugDescription)
        ccBcc.tap()
        XCTAssertTrue(app.buttons["compose.from-picker"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testSettingsSectionsOpenWithTheirTitles() {
        let app = launchRealistic()
        back(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        for (raw, title) in [("smartInbox", "Smart Inbox & AI"), ("notifications", "Notifications"),
                             ("privacy", "Privacy"), ("troubleshooting", "Troubleshooting"),
                             ("plainpostAccount", "Plainpost Account")] {
            app.buttons["settings.section.\(raw)"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
            XCTAssertFalse(app.buttons["mailbox.toolbar.compose"].exists, "\(title) shows the mailbox toolbar")
            if raw == "troubleshooting" {
                XCTAssertTrue(app.staticTexts["Last sync"].waitForExistence(timeout: 5), app.debugDescription)
            }
            back(in: app)
        }
    }

    /// Rules & Labels opens on its list even when labels exist: a label's editor
    /// opens only from its row or Add, and stays closed after going back.
    func testRulesAndLabelsOpensOnTheListWithLabelsPresent() {
        let app = launchRealistic()
        back(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let section = app.buttons["settings.section.rulesLabels"]
        func openRulesAndLabels() {
            for _ in 0..<4 where !section.isHittable { app.swipeUp() }
            section.tap()
            XCTAssertTrue(app.navigationBars["Rules & Labels"].waitForExistence(timeout: 5), app.debugDescription)
        }
        openRulesAndLabels()

        let addLabel = app.buttons["Add mail label"]
        for _ in 0..<4 where !addLabel.isHittable { app.swipeUp() }
        addLabel.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        title.tap()
        title.typeText("Receipts UI\n")
        let save = app.buttons["Save Label"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        back(in: app)

        // Back on the list: the saved label is listed and no editor is pushed.
        // The row reads "title, scope".
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Receipts UI")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.textFields["Title"].exists, "the editor re-opened after going back")

        // Opening the page again shows the list, not the first label's editor.
        back(in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        openRulesAndLabels()
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.textFields["Title"].exists, "opening Rules & Labels pushed a label editor")
        XCTAssertTrue(app.navigationBars["Rules & Labels"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "rules-labels-list"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // "Receipts UI" has no description, so its row's Smart Inbox toggle can't turn on:
        // it opens that label's editor with the reason. (A toggle that saves the flag
        // stays on the list; MailLabelsViewModelTests covers that.)
        let toggle = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "label.smart-inbox-toggle.")
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        toggle.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Receipts UI")
        XCTAssertTrue(
            app.staticTexts["Add a description before using this label in Smart Inbox."].exists,
            app.debugDescription
        )
        back(in: app)
        XCTAssertTrue(app.navigationBars["Rules & Labels"].waitForExistence(timeout: 5), app.debugDescription)

        // A row tap still opens that label's editor.
        row.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Receipts UI")
    }

    func testApprovalsOpenOnTheList() {
        let app = launchNode(["PLAINPOST_APPROVAL_QUEUE_UI_ACCEPTANCE": UUID().uuidString])
        back(in: app)
        app.buttons["mailboxes.row.approvals"].tap()
        XCTAssertTrue(app.navigationBars["Agent Approvals"].waitForExistence(timeout: 10))
        let request = app.staticTexts["Review the quarterly plan"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No approval request selected"].exists)
        request.tap()
        XCTAssertTrue(app.staticTexts["reviewer@example.test"].firstMatch.waitForExistence(timeout: 10))
    }

    func testRotationKeepsTheConversation() {
        let app = launchRealistic()
        openMaria(in: app)
        let subject = app.staticTexts["mailbox.reader.subject"]
        let window = app.windows.firstMatch
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
        XCTAssertTrue(waitUntil(timeout: 5) { window.frame.width > window.frame.height }, "the window never turned landscape")
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["3 Messages"].exists, "the conversation must survive the rotation")
        XCTAssertFalse(app.navigationBars["Mailboxes"].exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCUIDevice.shared.orientation, .portrait)
        XCTAssertTrue(waitUntil(timeout: 5) { window.frame.height > window.frame.width }, "the window never returned to portrait")
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["3 Messages"].exists)
    }

    func testRowsShowNamesAndCleanText() {
        let app = launchRealistic()
        XCTAssertTrue(row("Vercel, Deployment ready", in: app).waitForExistence(timeout: 10), "raw header sender shows only its name")
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !row("Anonymous, (No subject)", in: app).exists { list.swipeUp() }
        XCTAssertTrue(row("Anonymous, (No subject)", in: app).exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "<")).count, 0)
    }

    /// A row's accessibility label reads "sender, subject" (`MobileRowText.accessibilityLabel`);
    /// strips the sender to compare against `mailbox.reader.subject`.
    private static func subjectPart(of rowLabel: String) -> String {
        guard let range = rowLabel.range(of: ", ") else { return rowLabel }
        return String(rowLabel[range.upperBound...])
    }

    func testConversationStepsBetweenMessages() {
        let app = launchRealistic()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mailbox.row."))
        XCTAssertGreaterThanOrEqual(rows.count, 2, app.debugDescription)
        let firstLabel = rows.element(boundBy: 0).label
        let secondLabel = rows.element(boundBy: 1).label
        rows.element(boundBy: 0).tap()
        let subject = app.staticTexts["mailbox.reader.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(subject.label, Self.subjectPart(of: firstLabel), "opened row must be the list's first")
        XCTAssertFalse(app.buttons["conversation.toolbar.previous"].isEnabled, "Previous must be disabled on the first row")
        app.buttons["conversation.toolbar.next"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { subject.label == Self.subjectPart(of: secondLabel) },
                      "Next did not move to the next row; got \(subject.label)")
        app.buttons["conversation.toolbar.previous"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { subject.label == Self.subjectPart(of: firstLabel) },
                      "Previous did not return to the first row; got \(subject.label)")
        // ⌃⌄ must mutate the open conversation in place, not push a new one: after two steps,
        // a single Back still lands directly on the mailbox list.
        back(in: app)
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 5),
                      "⌃⌄ must not stack conversations: one Back should reach the mailbox list")
    }

    // MARK: Milestone 2

    func rowContaining(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }

    func testLeadingSwipeMarksRead() {
        let app = launchNode()
        let row = rowContaining("Analytical engine notes", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeRight()
        app.buttons["Read"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("markRead ada@example.test", timeout: 10))
    }

    /// The fixture account is Gmail, so its trailing swipe archives, as a Direct Gmail
    /// account's does.
    func testTrailingSwipeArchivesAfterTheUndoWindow() {
        let app = launchNode()
        let row = rowContaining("Analytical engine notes", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeLeft()
        app.buttons["Archive"].firstMatch.tap()
        XCTAssertTrue(app.buttons["mailbox.undo"].waitForExistence(timeout: 3), "Undo shows during the grace period")
        let mutation = app.staticTexts["debug.node-mutation.last"]
        // `debug.node-mutation.last` renders only once a mutation has landed (DebugNodeMutationLog),
        // so it doesn't exist yet here; `.labelIfExists` (PlainpostUITests.swift's own idiom for
        // this identifier) reads that safely instead of `.label`, which throws on a missing element.
        XCTAssertFalse(mutation.labelIfExists.hasPrefix("archive"), "nothing reaches the Node inside the Undo window")
        XCTAssertTrue(mutation.waitForLabel("archive ada@example.test", timeout: 10))
        XCTAssertTrue(app.buttons["mailbox.undo"].waitForNonExistence(timeout: 5))
    }

    func testUndoBringsTheRowBack() {
        let app = launchRealistic()
        let tom = row("Tom Okafor, Dinner on Saturday?", in: app)
        XCTAssertTrue(tom.waitForExistence(timeout: 10))
        tom.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(tom.waitForNonExistence(timeout: 3))
        app.buttons["mailbox.undo"].tap()
        XCTAssertTrue(tom.waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testContextMenuOffersTheRowActions() {
        let app = launchRealistic()
        let tom = row("Tom Okafor, Dinner on Saturday?", in: app)
        XCTAssertTrue(tom.waitForExistence(timeout: 10))
        tom.press(forDuration: 1.2)
        for title in ["Mark as Read", "Reply", "Forward", "Archive", "Delete"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), title)
        }
    }

    func testChipsFilterTheSmartInbox() {
        let app = launchRealistic()
        XCTAssertTrue(app.buttons["mailbox.chip.invitations"].waitForExistence(timeout: 10), "the fixture has an invitation")
        app.buttons["mailbox.chip.newsletters"].tap()
        XCTAssertTrue(rowContaining("Top 5 launches today", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("Maria Chen", in: app).exists)
        app.buttons["mailbox.chip.all"].tap()
        XCTAssertTrue(row("Maria Chen", in: app).waitForExistence(timeout: 5))
    }

    func testUnreadFilterHidesReadMail() {
        let app = launchRealistic()
        // "Landlord — Peter Novak" sorts 12th by recency; the list only materializes the first
        // screenful, so it needs scrolling into view first, same as testRowsShowNamesAndCleanText.
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !row("Landlord — Peter Novak", in: app).exists { list.swipeUp() }
        XCTAssertTrue(row("Landlord — Peter Novak", in: app).exists, app.debugDescription)
        app.buttons["mailbox.toolbar.filter"].tap()
        XCTAssertTrue(row("Landlord — Peter Novak", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("Tom Okafor", in: app).exists)
    }

    func testMarkedUnreadStaysUnreadAfterLeavingAndReturning() {
        let app = launchRealistic()
        openMaria(in: app)
        back(in: app)
        let maria = row("Maria Chen, Re: Quarterly planning", in: app)
        XCTAssertTrue(maria.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 10) { (maria.value as? String) != "Unread" }, "opening marks it read")
        maria.swipeRight()
        app.buttons["Unread"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (maria.value as? String) == "Unread" }, app.debugDescription)

        // A detour through another mailbox must not restore Maria as a hidden selection,
        // which would mark it read again.
        back(in: app)
        app.buttons["mailboxes.row.allInboxes"].tap()
        XCTAssertTrue(app.navigationBars["All Inboxes"].waitForExistence(timeout: 5))
        back(in: app)
        app.buttons["mailboxes.row.smartInbox"].tap()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(maria.waitForExistence(timeout: 5))
        XCTAssertFalse(waitUntil(timeout: 3) { (maria.value as? String) != "Unread" }, "Maria was marked read again")
    }

    func testFlagFromTheLeadingSwipeReachesTheNode() {
        let app = launchNode()
        let row = rowContaining("Analytical engine notes", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeRight()
        app.buttons["Flag"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("flag ada@example.test", timeout: 10))
    }

    /// Move to… lists the message's account's other folders; the fixture account's only
    /// mirrored folder is its Inbox, so the sheet says there is nowhere else to go.
    func testMoveToOpensWithTheAccountsOtherFolders() {
        let app = launchNode()
        let row = rowContaining("Analytical engine notes", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
        app.buttons["conversation.toolbar.more"].tap()
        app.buttons["conversation.more.move"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No other folders"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForNonExistence(timeout: 5))
    }

    func testMarkAllAsReadReachesTheNode() {
        let app = launchNode()
        XCTAssertTrue(rowContaining("Analytical engine notes", in: app).waitForExistence(timeout: 30))
        app.buttons["mailbox.toolbar.more"].tap()
        app.buttons["Mark All as Read"].tap()
        XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("markRead ada@example.test", timeout: 10))
    }

    // testNextOpensTheFollowingConversationInPlace (brief, Milestone 2) is skipped: it
    // duplicates testConversationStepsBetweenMessages (Task 14, using the real
    // conversation.toolbar.previous/next identifiers), which now also carries the brief test's
    // "never stacks" check directly: after two ⌃⌄ steps, a single Back must land on the mailbox
    // list (added above per the Task 18 review finding).

    func testFoldersOpenFromMailboxes() {
        let app = launchRealistic()
        back(in: app)
        let sent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "mailboxes.folder.", "Sent")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), app.debugDescription)
        sent.tap()
        XCTAssertTrue(app.navigationBars["Sent"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("Reader, Re: Quarterly planning", in: app).waitForExistence(timeout: 10))
    }

    func testEmptyFolderShowsContentUnavailable() {
        let app = launchRealistic()
        back(in: app)
        let drafts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "mailboxes.folder.", "Drafts")).firstMatch
        XCTAssertTrue(drafts.waitForExistence(timeout: 10))
        drafts.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mailbox.empty"].waitForExistence(timeout: 10))
    }

    // The Task 15 note asks for a UI test of "a committed archive in a folder row stays gone
    // after the 4 s window, on the Node fixture." It doesn't fit: `launchNode()`'s debug
    // single-account fixture (DebugTwoAccountNodeSender) has no local `Account` store row, and
    // `PlainpostAppRuntime.mailboxDirectorySections()` requires one (`store.accounts.first(where:
    // { $0.id == accountID })`) before it lists any account section at all. Confirmed empirically:
    // waiting for `mailboxes.folder.` under `launchNode()` times out with zero `mailboxes.account.`
    // or `mailboxes.folder.` elements anywhere in the tree (see task-18-report.md). The regression
    // itself is already pinned at the unit level by
    // `FolderRowsModelTests.testANodeFolderReloadsOnceTheSnapshotLands` and
    // `testCommittedArchiveAndDeleteLeaveTheLoadedRows`. No UI test is added for this; the
    // device checklist (Step 3, item 7/8) is the only place a real Node account's folders are
    // exercised end-to-end.

    // MARK: Milestone 3

    func openSearch(in app: XCUIApplication, typing query: String) -> XCUIElement {
        app.buttons["mailbox.toolbar.search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        return field
    }

    func testSearchResultBackReturnsToResults() {
        let app = launchRealistic()
        let field = openSearch(in: app, typing: "parcel")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), app.debugDescription)
        hit.tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
        back(in: app)
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "parcel", "Back from a hit keeps the query")
        XCTAssertTrue(hit.exists, "and its results")
    }

    func testSearchFindsSeededMailAndSuggestsAttachments() {
        let app = launchRealistic()
        _ = openSearch(in: app, typing: "Post")
        XCTAssertTrue(rowContaining("Parcel update", in: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["search.suggestion.has-attachment"].exists)
        XCTAssertFalse(app.staticTexts["bcc:legal"].exists, "no query-syntax cheat sheet")
    }

    func testComposeSuggestsPeopleFromYourMail() {
        let app = launchRealistic()
        app.buttons["mailbox.toolbar.compose"].tap()
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("mar")
        let maria = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "maria.chen@northwind.example")).firstMatch
        XCTAssertTrue(maria.waitForExistence(timeout: 10), app.debugDescription)
        maria.tap()
        XCTAssertTrue(app.buttons["compose.token.to.maria.chen@northwind.example"].waitForExistence(timeout: 5))
    }

    /// Ledger Task 21: Return turns the typed address into a token and moves on, To → Subject
    /// (Cc and Bcc are collapsed) → the body.
    func testReturnMovesFromToThroughSubjectToTheBody() {
        let app = launchRealistic()
        app.buttons["mailbox.toolbar.compose"].tap()
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("someone@example.test\n")
        XCTAssertTrue(app.buttons["compose.token.to.someone@example.test"].waitForExistence(timeout: 5))
        app.typeText("Plans\n")
        XCTAssertEqual(app.textFields["Subject"].value as? String, "Plans")
        app.typeText("See you then")
        XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains("See you then") == true,
                      app.debugDescription)
    }

    /// Ledger Task 21: a tap selects a recipient token; Remove, the second step, removes it.
    func testRemovingARecipientTakesSelectThenRemove() {
        let app = launchRealistic()
        openMaria(in: app)
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        let token = app.buttons["compose.token.to.maria.chen@northwind.example"]
        XCTAssertTrue(token.waitForExistence(timeout: 10))
        token.tap()
        let remove = app.buttons["compose.token-remove.to.maria.chen@northwind.example"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(token.exists, "one tap only selects the recipient")
        remove.tap()
        XCTAssertTrue(token.waitForNonExistence(timeout: 5))
    }

    func testComposeCloseOffersSaveOrDelete() {
        let app = launchRealistic()
        app.buttons["mailbox.toolbar.compose"].tap()
        let subject = app.textFields["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        subject.typeText("An unfinished note")
        app.buttons["compose.close"].tap()
        XCTAssertTrue(app.buttons["Save Draft"].waitForExistence(timeout: 5))
        // Task 23b: this dialog is now an .alert, so it never collapses into a Cancel-less
        // popover the way a confirmationDialog nested in this sheet did.
        XCTAssertTrue(app.buttons["Cancel"].exists, "Cancel must stay visible")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(subject.value as? String, "An unfinished note")
        app.buttons["compose.close"].tap()
        app.buttons["Delete Draft"].tap()
        XCTAssertTrue(app.buttons["compose.close"].waitForNonExistence(timeout: 10))
    }

    func testComposeSheetAcceptsTypingAndKeepsSendVisible() {
        let app = launchRealistic()
        openMaria(in: app)
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        XCTAssertTrue(app.buttons["compose.token.to.maria.chen@northwind.example"].waitForExistence(timeout: 10),
                      "Reply fills To with a token")
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.tap()
        body.typeText("Typed into the reply")
        XCTAssertTrue((body.value as? String)?.contains("Typed into the reply") == true)
        XCTAssertTrue(app.buttons["compose.send"].isHittable, "Send stays in the sheet's top bar above the keyboard")
    }

    /// A read-only account can't send, so Compose is disabled on Mailboxes, the list and a
    /// conversation, as are the Reply menu's reply items.
    func testComposeIsDisabledWhileTheAccountIsReadOnly() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_READ_ONLY_MAIL": "1"])
        let compose = app.buttons["mailbox.toolbar.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertFalse(compose.isEnabled, "the list's Compose")
        openMaria(in: app)
        XCTAssertFalse(compose.isEnabled, "the conversation's Compose")
        // The Reply menu still opens, with its reply items disabled.
        app.buttons["conversation.toolbar.reply"].tap()
        XCTAssertTrue(app.buttons["conversation.reply-menu.reply"].waitForExistence(timeout: 5))
        for item in ["reply", "reply-all", "forward"] {
            XCTAssertFalse(app.buttons["conversation.reply-menu.\(item)"].isEnabled, item)
        }
        // Dismiss the menu by tapping the navigation bar's title area.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        XCTAssertTrue(app.buttons["conversation.reply-menu.reply"].waitForNonExistence(timeout: 5))
        back(in: app)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 10))
        XCTAssertFalse(compose.isEnabled, "Mailboxes' Compose")
    }

    /// Final-review Minor 7: the read-only line names the actual reason. The debug flag opens the
    /// mail read-only as an offline lease does, with no known expiry.
    func testReadOnlyListNamesItsReason() {
        let app = launchRealistic(environment: ["PLAINPOST_UI_TEST_READ_ONLY_MAIL": "1"])
        let line = app.descendants(matching: .any)["mailbox.read-only"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(line.label, "Offline: cached mail is read-only until Plainpost reconnects.")
    }

    /// Final-review Minor 2: a notification tapped while the draft has unsaved changes waits,
    /// and the line saying so shows in the Compose sheet, which covers the screens that had it.
    func testDeferredNotificationLineShowsInCompose() {
        let app = launchNode(["PLAINPOST_UI_TEST_NOTIFICATION_TAP_WHILE_COMPOSING": "1"])
        app.buttons["mailbox.toolbar.compose"].tap()
        let subject = app.textFields["Subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        subject.typeText("Unsaved")
        // The Mailboxes list behind the sheet shows the same line.
        let lines = app.staticTexts.matching(NSPredicate(format: "label == %@", "Save or close the draft to open the notification."))
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let sheetTop = app.buttons["compose.close"].frame.minY
        XCTAssertTrue(
            lines.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minY > sheetTop },
            "the line is in the sheet, below its ✕, not only behind it"
        )
    }

    func testFailedSendOffersOpenDraft() {
        let app = launchNode(["PLAINPOST_DEBUG_NODE_FAILING_SEND": "1"])
        app.buttons["mailbox.toolbar.compose"].tap()
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("someone@example.test,")
        app.textFields["Subject"].tap()
        app.textFields["Subject"].typeText("Rejected")
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("This send fails")
        app.buttons["compose.send"].tap()
        XCTAssertTrue(app.staticTexts["debug.node-mutation.last"].waitForLabel("send rejected ada@example.test", timeout: 30))
        let openDraft = app.buttons["Open Draft"]
        XCTAssertTrue(openDraft.waitForExistence(timeout: 10))
        openDraft.tap()
        XCTAssertTrue(app.buttons["compose.close"].waitForExistence(timeout: 10))
    }

    func testReplySendAndUndoSend() {
        let app = launchNode()
        let ada = rowContaining("Analytical engine notes", in: app)
        XCTAssertTrue(ada.waitForExistence(timeout: 30))
        ada.tap()
        app.buttons["conversation.toolbar.reply"].tap()
        app.buttons["conversation.reply-menu.reply"].tap()
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.tap()
        body.typeText("Sent, then undone")
        app.buttons["compose.send"].tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the undo-send snackbar shows")
        undo.tap()
        XCTAssertTrue(app.buttons["compose.close"].waitForExistence(timeout: 10), "Undo reopens the draft")
        XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains("Sent, then undone") == true)
        XCTAssertFalse(app.staticTexts["debug.node-mutation.last"].label.hasPrefix("send"), "nothing was sent")
    }

    func askMailField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)",
            "Ask Mail", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
    }

    func launchAskMail(readOnly: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_ASK_MAIL_UI_ACCEPTANCE"] = UUID().uuidString
        if readOnly { app.launchEnvironment["PLAINPOST_UI_TEST_READ_ONLY_MAIL"] = "1" }
        app.launch()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 120))
        return app
    }

    func testAskMailSheetOpensAndAnswers() {
        let app = launchAskMail(readOnly: false)
        app.buttons["mailbox.toolbar.ask-mail"].tap()
        let field = askMailField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Group my unread emails, I want to clean some of them\n")
        XCTAssertTrue(app.staticTexts["Automated"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Mark read"].firstMatch.waitForExistence(timeout: 10))
    }

    func testAskMailSheetHidesActionsWhenReadOnly() {
        let app = launchAskMail(readOnly: true)
        app.buttons["mailbox.toolbar.ask-mail"].tap()
        let field = askMailField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Group my unread emails\n")
        XCTAssertTrue(app.staticTexts["Automated"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Mark read"].exists)
    }

    /// Task 21's review asked for this: Contacts access is asked only when a recipient field
    /// first gets focus, never just from opening the sheet. `launchRealistic()`'s
    /// `ContactDirectoryModel` starts `.notDetermined` (`PreviewContactDirectoryClient`, wired
    /// as `.designPreview()` for `PLAINPOST_REALISTIC_MAIL_UI_ACCEPTANCE`), and Settings ▸
    /// Privacy's "Apple Contacts" row reads that same model's snapshot
    /// (`ContactDirectorySettingsGroup`), so its `settingsLabel` ("Not enabled" while
    /// undetermined, "Denied" once the fixture's `requestAccess()` — which always returns
    /// false — has been asked) is a visible witness of whether the client was asked yet.
    func contactsAuthorizationLabel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Apple Contacts")).firstMatch
    }

    func testContactsIsAskedOnlyOnFirstRecipientFocus() {
        let app = launchRealistic()
        back(in: app)

        func openPrivacy() {
            app.buttons["mailboxes.row.settings"].tap()
            app.buttons["settings.section.privacy"].tap()
        }

        // Opening and closing the Compose sheet without ever focusing a recipient field must
        // not ask Contacts (the sheet itself never calls prepareContactsIfNeeded).
        app.buttons["mailbox.toolbar.compose"].tap()
        XCTAssertTrue(app.textFields["To recipients"].waitForExistence(timeout: 10))
        app.buttons["compose.close"].tap()
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        openPrivacy()
        let contacts = contactsAuthorizationLabel(in: app)
        XCTAssertTrue(contacts.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(contacts.value as? String, "Not enabled", "opening the Compose sheet must not ask Contacts")
        back(in: app)
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))

        // The first focus on a recipient field does ask.
        app.buttons["mailbox.toolbar.compose"].tap()
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        app.buttons["compose.close"].tap()
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        openPrivacy()
        let contactsAfterFocus = contactsAuthorizationLabel(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { (contactsAfterFocus.value as? String) == "Denied" },
                      "the first recipient-field focus must ask; got \(contactsAfterFocus.value as? String ?? "<none>")")
    }

    // MARK: Milestone 4: paths

    /// Both of the Sync Node's accounts are in one list, and Mailboxes has no account switcher.
    func testSyncNodeAccountsShareOneListWithNoSwitcher() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 120))
        XCTAssertTrue(rowContaining("Analytical engine notes", in: app).waitForExistence(timeout: 30))
        XCTAssertTrue(rowContaining("Compiler review", in: app).waitForExistence(timeout: 30))
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mail-account.switcher"].exists)
        XCTAssertFalse(app.buttons["mailboxes.account-switcher"].exists)
    }

    /// A Sync Node account's settings offer Google sign-in on this iPhone, which keeps it
    /// syncing while its Node is away; the Direct-only rows aren't there.
    func testASyncNodeAccountsSettingsOfferToKeepItSyncingHere() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Smart Inbox"].waitForExistence(timeout: 120))
        XCTAssertTrue(rowContaining("Compiler review", in: app).waitForExistence(timeout: 30))
        back(in: app)
        app.buttons["mailboxes.row.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let grace = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'settings.account.' AND label CONTAINS 'grace@example.test'"
        )).firstMatch
        XCTAssertTrue(grace.waitForExistence(timeout: 10), app.debugDescription)
        grace.tap()
        XCTAssertTrue(app.navigationBars["grace@example.test"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["account.sync-node.sign-in"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["local-mail.attach-node"].exists)
        XCTAssertFalse(app.buttons["Change Password…"].exists)
    }

    /// A Sync Node push opens its message in place, whichever account it came to, with no
    /// account switch.
    func testANotificationTapOpensTheSecondSyncNodeAccountsMessageInPlace() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_UI_TEST_NOTIFICATION_TAP_NODE_MESSAGE"] = "gm2.00000000000000000000000000000000000000a2"
        app.launch()
        let more = app.buttons["conversation.toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Compiler review"].firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["mailbox.notice"].exists)
    }

    /// A push for a message this iPhone doesn't have says so, on All Inboxes.
    func testANotificationTapForMissingMailSaysSo() {
        let app = XCUIApplication()
        app.launchEnvironment["PLAINPOST_MULTI_ACCOUNT_UI_ACCEPTANCE"] = "1"
        app.launchEnvironment["PLAINPOST_UI_TEST_NOTIFICATION_TAP_NODE_MESSAGE"] = "missing"
        app.launch()
        let notice = app.descendants(matching: .any)["mailbox.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertTrue(notice.label.contains("This message is no longer on this iPhone."), notice.label)
    }

    // MARK: Milestone 4: accessibility

    func testRowsWrapAtAccessibilitySizes() {
        let app = launchRealistic(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let tom = row("Tom Okafor, Dinner on Saturday?", in: app)
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 where !tom.exists { list.swipeUp() }
        XCTAssertTrue(tom.exists)
        XCTAssertGreaterThan(tom.frame.height, 140, "at AX5 the row wraps its subject instead of cutting it to a word")
        XCTAssertLessThanOrEqual(tom.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    func assertControlsAreLabelledAndLargeEnough(in app: XCUIApplication, screen: String) {
        // iOS 26 draws navigation-bar and bottom-toolbar items itself: their frames are 36–38 pt
        // whatever frame the app gives the label, and their hit area is the system's (the
        // `.hitRegion` audit accepts them). Their labels are checked; their size is the system's.
        func isSystemBarItem(_ button: XCUIElement) -> Bool {
            let barButtons = [app.navigationBars.buttons, app.toolbars.buttons]
            if !button.identifier.isEmpty { return barButtons.contains { $0[button.identifier].exists } }
            return barButtons.contains { $0.allElementsBoundByIndex.contains { $0.frame == button.frame } }
        }
        for button in app.buttons.allElementsBoundByIndex where button.exists && button.isHittable {
            XCTAssertFalse(button.label.trimmingCharacters(in: .whitespaces).isEmpty, "\(screen): unlabelled \(button.debugDescription)")
            if isSystemBarItem(button) { continue }
            // A 44 pt view at a fractional origin reads back as 43.99999…
            let minimum: CGFloat = 44 - 0.01
            XCTAssertGreaterThanOrEqual(button.frame.height, minimum, "\(screen): \(button.label) is \(button.frame.height) pt tall")
            XCTAssertGreaterThanOrEqual(button.frame.width, minimum, "\(screen): \(button.label) is \(button.frame.width) pt wide")
        }
    }

    func testEveryVisibleControlHasALabelAndA44PointTarget() {
        let app = launchRealistic()
        assertControlsAreLabelledAndLargeEnough(in: app, screen: "Smart Inbox")
        openMaria(in: app)
        assertControlsAreLabelledAndLargeEnough(in: app, screen: "Conversation")
        back(in: app)
        back(in: app)
        assertControlsAreLabelledAndLargeEnough(in: app, screen: "Mailboxes")
    }

    func testAccessibilityAuditPassesOnTheMainScreens() throws {
        let app = launchRealistic()
        // Clipping is audited at an accessibility size below: at the default size a row's
        // one-line subject and two-line preview truncate by design.
        let audit: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion, .dynamicType]
        try app.performAccessibilityAudit(for: audit)
        openMaria(in: app)
        try app.performAccessibilityAudit(for: audit)
        back(in: app)
        back(in: app)
        // Audit artifact on a List (task-28b report): the Dynamic Type audit captures each text
        // once, then calls reloadData at each of its 12 sizes and reads the font again. A row
        // pushed below the screen at a larger size isn't re-rendered, so its text keeps the
        // last font and is called "partially unsupported". Which rows that hits depends on the
        // screen height: Activity on every iPhone, and Settings and the account title on a 17e.
        // Only that finding, on a text inside the Mailboxes list, is tolerated;
        // testMailboxesLabelsGrowAtAccessibilitySizes checks that those texts do grow.
        let list = app.collectionViews.firstMatch
        try app.performAccessibilityAudit(for: audit) { issue in
            guard issue.auditType == .dynamicType,
                  issue.compactDescription == "Dynamic Type font sizes are partially unsupported",
                  let element = issue.element, element.elementType == .staticText else { return false }
            return list.staticTexts.matching(NSPredicate(format: "label == %@", element.label))
                .allElementsBoundByIndex.contains { $0.frame == element.frame }
        }
    }

    /// The text height of each Mailboxes label the audit can't follow, scrolling each into view.
    func mailboxesTextHeights(in app: XCUIApplication) -> [String: CGFloat] {
        back(in: app)
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 5))
        let list = app.collectionViews.firstMatch
        let accountTitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mailboxes.account."))
            .firstMatch.staticTexts.firstMatch
        // Top to bottom, so the list only ever scrolls down.
        let labels: [(String, XCUIElement)] = [
            ("Settings", app.buttons["mailboxes.row.settings"].staticTexts["Settings"].firstMatch),
            ("account title", accountTitle),
            ("Trash", list.staticTexts["Trash"].firstMatch),
            ("Activity", list.staticTexts["Activity"].firstMatch),
        ]
        var heights: [String: CGFloat] = [:]
        for (name, text) in labels {
            // Short drags without momentum, so a label can't skip past the screen.
            for _ in 0..<15 where !(text.exists && text.isHittable) {
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            }
            XCTAssertTrue(text.isHittable, "\(name) is on screen: \(app.debugDescription)")
            heights[name] = text.frame.height
        }
        return heights
    }

    func testMailboxesLabelsGrowAtAccessibilitySizes() {
        let regular = mailboxesTextHeights(in: launchRealistic())
        let large = mailboxesTextHeights(in: launchRealistic(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]))
        // At AX5 body rows are about 3× taller and the Activity header, whose frame carries
        // fixed padding, about 2.1×. A clamp at the largest non-accessibility size leaves every
        // label at 1.4× or less. Every label that doesn't grow is named at once.
        let clamped = regular.keys.sorted().filter { (large[$0] ?? 0) <= regular[$0]! * 1.6 }
            .map { "\($0): \(regular[$0]!) → \(large[$0] ?? 0)" }
        XCTAssertEqual(clamped, [], "Mailboxes labels grow with Dynamic Type")
    }

    func testNoTextClipsAtAccessibilitySizes() throws {
        let app = launchRealistic(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let audit: XCUIAccessibilityAuditType = [.textClipped, .dynamicType]
        try app.performAccessibilityAudit(for: audit)
        let maria = row("Maria Chen, Re: Quarterly planning", in: app)
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 where !(maria.exists && maria.isHittable) { list.swipeUp() }
        maria.tap()
        XCTAssertTrue(app.staticTexts["mailbox.reader.subject"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: audit)
        back(in: app)
        back(in: app)
        try app.performAccessibilityAudit(for: audit)
    }

    func testRowActionDialogListsEachActionOnce() {
        let app = launchRealistic()
        let tom = row("Tom Okafor, Dinner on Saturday?", in: app)
        XCTAssertTrue(tom.waitForExistence(timeout: 10))
        tom.swipeLeft()
        // The row's swipe action, not the toolbar's More menu.
        app.collectionViews.firstMatch.buttons["More"].tap()
        let dialog = app.sheets["Dinner on Saturday?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), app.debugDescription)
        for title in ["Mark as Read", "Reply", "Forward", "Archive"] {
            let matches = dialog.buttons.matching(NSPredicate(format: "label == %@", title))
            XCTAssertEqual(matches.count, 1, "VoiceOver must meet \(title) once: \(dialog.debugDescription)")
        }
    }

    func testApprovalReviewFitsAtAccessibilitySize() {
        let app = launchNode(
            ["PLAINPOST_APPROVAL_QUEUE_UI_ACCEPTANCE": UUID().uuidString],
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        )
        back(in: app)
        app.buttons["mailboxes.row.approvals"].tap()
        let request = app.staticTexts["Review the quarterly plan"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        let window = app.windows.firstMatch
        for action in [app.buttons["Don't Send"], app.buttons["Send Now"]] {
            XCTAssertTrue(action.waitForExistence(timeout: 10))
            XCTAssertTrue(action.isHittable)
            XCTAssertLessThanOrEqual(action.frame.maxX, window.frame.maxX)
            XCTAssertLessThanOrEqual(action.frame.maxY, window.frame.maxY)
        }
    }

    // MARK: Visual QA (Task 27)

    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testVisualQAScreens() {
        let app = launchRealistic()
        attach(app, "02-smart-inbox")
        back(in: app)
        attach(app, "01-mailboxes")
        app.buttons["mailboxes.row.smartInbox"].tap()
        openMaria(in: app)
        attach(app, "03-conversation")
        back(in: app)
        row("Tom Okafor", in: app).press(forDuration: 1.2)
        attach(app, "04-context-menu")
        // Dismiss on the menu's dimmed backdrop: a status-bar tap never reaches it, and the
        // close animation briefly covers the bottom bar.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["mailbox.toolbar.search"].isHittable })
        _ = openSearch(in: app, typing: "parcel")
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")).firstMatch.waitForExistence(timeout: 30)
        attach(app, "05-search")
        back(in: app)
        app.buttons["mailbox.toolbar.compose"].tap()
        let to = app.textFields["To recipients"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("mar")
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "maria.chen@northwind.example")).firstMatch.waitForExistence(timeout: 10)
        attach(app, "06-compose")
    }

    func testVisualQAAskMailSheet() {
        let app = launchAskMail(readOnly: false)
        app.buttons["mailbox.toolbar.ask-mail"].tap()
        let field = askMailField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("What am I waiting on replies for?\n")
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 20)
        attach(app, "07-ask-mail")
    }

}

private extension XCUIElement {
    var labelIfExists: String {
        exists ? label : "<none>"
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
