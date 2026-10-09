import Foundation
import XCTest

final class IOSMailProductAssemblyTests: XCTestCase {
    func testAuthorizedIOSContentUsesProductionMailRuntime() throws {
        let app = try source(at: "Apps/PlainpostiOS/Plainpost/PlainpostApp.swift")
        // The runtime preparation lives beside the root view it serves.
        let mailRoot = try source(at: "Apps/PlainpostiOS/Plainpost/MobileMailRootView.swift")
            + source(at: "Apps/PlainpostiOS/Plainpost/MobileMailRuntimeModel.swift")

        XCTAssertTrue(mailRoot.contains("PlainpostAppRuntime"))
        // The production root owns the controller specialised to the real runtime,
        // and that controller builds `PlainpostAppRuntime` from the selected authority.
        XCTAssertTrue(mailRoot.contains("typealias MobileMailRuntimeModel = MobileMailRuntimeController<PlainpostAppRuntime>"))
        XCTAssertTrue(mailRoot.contains("_model = StateObject(wrappedValue: MobileMailRuntimeModel(localLaunchModel: localLaunchModel))"))
        XCTAssertTrue(mailRoot.contains("extension MobileMailRuntimeController where Runtime == PlainpostAppRuntime {"))
        XCTAssertTrue(mailRoot.contains("return try localLaunchModel.makeLocalRuntime(readOnly: readOnly)"))
        XCTAssertTrue(mailRoot.contains("return try localLaunchModel.makeNodeRuntime("))
        // Each runtime's views get their own identity.
        XCTAssertTrue(mailRoot.contains("MobileMailRuntimeScoped(generation: model.runtimeGeneration) {\n                    runtime.makeRootView("))
        XCTAssertTrue(mailRoot.contains("content().id(generation)"))
        XCTAssertTrue(mailRoot.contains("composerPresentationPolicy: .embedded,"))
        // iPhone renders the native shell on its own session; iPad keeps the split-view root.
        XCTAssertTrue(mailRoot.contains("static func usesMobileShell(idiom: UIUserInterfaceIdiom) -> Bool { idiom == .phone }"))
        XCTAssertTrue(mailRoot.contains("MobileMailShell(\n                        session: runtime.makeMailSession("))
        XCTAssertTrue(mailRoot.contains("contactDirectory: contactDirectory"))
        // The orphaned toolbar outside any navigation container is gone (F6): Task 1's iPad
        // baseline found it never rendered on iPad either, so it is deleted, not wrapped.
        XCTAssertFalse(mailRoot.contains("accessibilityIdentifier(\"direct-mail.sync\")"))
        // The shell's environment follows the host: pull to refresh is rebuilt from its inputs,
        // and a runtime switch refreshes From.
        XCTAssertFalse(mailRoot.contains(".onAppear(perform: configureMobileEnvironment)"))
        XCTAssertTrue(mailRoot.contains(".onChange(of: Self.mobileSyncActionKey(route: route, readOnly: readOnly, scenePhase: scenePhase), initial: true)"))
        let generationChange = try XCTUnwrap(mailRoot.range(of: ".onChange(of: model.runtimeGeneration)"))
        let storeChange = try XCTUnwrap(mailRoot.range(of: ".onReceive(MailStoreChangeSignal.mainThreadChanges)", range: generationChange.upperBound..<mailRoot.endIndex))
        let refresh = mailRoot[generationChange.upperBound..<storeChange.lowerBound]
        XCTAssertTrue(refresh.contains("restartDirectMailLifecycle()"))
        XCTAssertTrue(refresh.contains("refreshRuntimeAccounts()"))
        XCTAssertTrue(mailRoot.contains("mobileEnvironment.fromAddress = fromAddress(accounts: accounts)"))
        // Every account is in one list: no local account menu.
        XCTAssertFalse(app.contains("localAccountMenuKey"))
        // The account header is stacked above the runtime's navigation
        // container. A top inset or overlay is drawn over its navigation bar.
        XCTAssertNotNil(mailRoot.range(
            of: #"VStack\(spacing: 0\) \{\s*accountChrome"#,
            options: .regularExpression
        ))
        XCTAssertTrue(mailRoot.contains("            accountChrome\n"))
        XCTAssertTrue(mailRoot.contains("            mailContent\n        }"))
        XCTAssertFalse(mailRoot.contains(".safeAreaInset(edge: .top"))
        XCTAssertFalse(mailRoot.contains(".overlay(alignment: .top"))
        // One runtime serves every account: no account switch waits on a failed send's notice.
        XCTAssertTrue(mailRoot.contains("isUserAccountSwitch: false"))
        XCTAssertFalse(mailRoot.contains("isUserSelectedMailAuthority"))
        // There is no account switcher to disable.
        XCTAssertFalse(mailRoot.contains("isSwitchingDisabled"))
        // Nothing floats over the mail, so nothing measures floating controls.
        XCTAssertFalse(mailRoot.contains("reservedTop"))
        XCTAssertFalse(mailRoot.contains("mobileFloatingAccountControlsBottom"))
        // The hold status is one accessibility element and is announced.
        XCTAssertTrue(mailRoot.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(mailRoot.contains("AccessibilityNotification.Announcement(hold.statusText).post()"))
        // Discovered Google mailboxes never outlive their runtime.
        XCTAssertTrue(mailRoot.contains(".onChange(of: model.runtimeGeneration) { _, _ in"))
        // Google onboarding configures the primary account only.
        XCTAssertTrue(mailRoot.contains("providerOnboarding: allowsGoogleProviderOnboarding ? { beginGoogleAuthorization() } : nil"))
        // The host reads presentation state from the runtime's store. Importing
        // PlainpostDB for those reads does not grant it runtime/store ownership.
        // Constructors and factory/authority/fence assertions above protect that seam.
        XCTAssertFalse(mailRoot.contains("SQLiteMailStore"))
        XCTAssertFalse(mailRoot.contains("hasLocalProjection"))
        XCTAssertTrue(mailRoot.contains("PlainpostRuntimePreparationFence"))
        XCTAssertTrue(mailRoot.contains("preparationFence.isCurrent(generation)"))
        XCTAssertTrue(mailRoot.contains("await previousRuntime?.shutdown()"))
        XCTAssertTrue(mailRoot.contains("guard !Task.isCancelled, preparationFence.isCurrent(generation) else { return }"))
        XCTAssertTrue(mailRoot.contains("await nextRuntime.shutdown()"))
        XCTAssertTrue(mailRoot.contains("case .nodeUnavailable:"))
        XCTAssertTrue(mailRoot.contains("throw PlainpostError.permissionDenied(\"Sync Node is unavailable.\")"))
        XCTAssertTrue(app.contains("PLAINPOST_MAILBOX_UI_ACCEPTANCE"))
        XCTAssertTrue(app.contains("PLAINPOST_SIGNED_OUT_UI_ACCEPTANCE"))
        XCTAssertTrue(app.contains(".debugAuthorized()"))
        // A notification open rebuilds the mail root: the shell starts at that conversation
        // and any open sheet closes.
        XCTAssertTrue(mailRoot.contains(".id(model.notificationOpen.map"))
        // An account switch lets Undo-window actions reach the old runtime first.
        XCTAssertTrue(mailRoot.contains("await mobileEnvironment.commitPendingActions()"))
        XCTAssertTrue(app.contains(".debugSignedOut()"))
        XCTAssertFalse(app.contains("UnavailableSyncNodeMailWorkspace"))
        XCTAssertFalse(app.contains("SyncNodeMailWorkspace"))
    }

    func testIOSProjectDoesNotCompileLegacyPairedMacMailClient() throws {
        let project = try source(at: "Apps/PlainpostiOS/Plainpost.xcodeproj/project.pbxproj")

        for legacyClientSource in [
            "MobileMailWorkspace.swift",
            "MobileAIViews.swift",
            "MobileComposeAccessory.swift",
            "MobileComposerModel.swift",
            "MobileConversationTimeline.swift",
            "MobileMessageListView.swift",
            "MobileConversationView.swift",
            "MobileComposeViews.swift",
            "MobileRecipientTokens.swift",
            "MobileReceivedAttachmentViews.swift",
            "MobileMailboxNavigator.swift",
            "MobileSearchDestinationView.swift",
            "MobileCompanionSettingsView.swift",
        ] {
            XCTAssertFalse(
                project.contains(legacyClientSource),
                "paired-Mac client source remains in iOS target: \(legacyClientSource)"
            )
        }
    }

    func testMacOnlyLocalAPIServerCannotBlockIOSMailRuntime() throws {
        let runtime = try source(at: "Sources/PlainpostUI/PlainpostAppRuntime.swift")
        let serverConstruction = try XCTUnwrap(
            runtime.range(of: "let localAPIServer = try PlainpostLocalServerFactory.make")
        )
        let platformGuard = try XCTUnwrap(
            runtime.range(
                of: "#if os(macOS)",
                options: .backwards,
                range: runtime.startIndex..<serverConstruction.lowerBound
            )
        )
        XCTAssertLessThan(
            runtime.distance(from: platformGuard.lowerBound, to: serverConstruction.lowerBound),
            160
        )
    }

    func testMailRootDoesNotForceDesktopWidthOnIOS() throws {
        let root = try source(at: "Sources/PlainpostUI/PlainpostRootView.swift")
        XCTAssertTrue(root.contains("#if os(iOS)\n        0\n        #else\n        standardMinimumWindowWidth"))
        XCTAssertTrue(root.contains("private static var composerWidth: CGFloat?"))
    }

    /// A desktop minimum height pushed the navigation bar off an iPhone in
    /// landscape and the composer's Send bar under the keyboard.
    func testMailRootDoesNotForceDesktopHeightOnIOS() throws {
        let root = try source(at: "Sources/PlainpostUI/PlainpostRootView.swift")
        XCTAssertTrue(root.contains("static var mailboxRootMinimumHeight: CGFloat? {\n        #if os(iOS)\n        nil\n        #else\n        640"))
        XCTAssertTrue(root.contains("minHeight: Self.mailboxRootMinimumHeight,"))
        XCTAssertTrue(root.contains("static var composerBottomPadding: CGFloat {\n        #if os(iOS)\n        0\n        #else\n        96"))
        XCTAssertTrue(root.contains(".padding(.bottom, Self.composerBottomPadding)"))
        XCTAssertFalse(root.contains("minHeight: 640"))
        let composer = try source(at: "Sources/PlainpostUI/PlainpostComposerViews.swift")
        XCTAssertTrue(composer.contains(".frame(minHeight: Self.minimumEditorHeight, maxHeight: .infinity)"))
    }

    /// The account controls are laid out above the mail, never floated over
    /// its navigation bar, composer or snackbar.
    func testAccountRootStacksItsControlsAboveTheMail() throws {
        let accountRoot = try source(at: "Apps/PlainpostiOS/Plainpost/MobileAccountRootView.swift")
        let activeStart = try XCTUnwrap(accountRoot.range(of: "case .active:"))
        let activeEnd = try XCTUnwrap(accountRoot.range(of: "case .offlineLease", range: activeStart.upperBound..<accountRoot.endIndex))
        let active = accountRoot[activeStart.upperBound..<activeEnd.lowerBound]
        XCTAssertTrue(active.contains("VStack(spacing: 0) {\n                if !isCompactKeyboardEditing {\n                    activeAccountChrome\n                }\n                authorizedContent(false, nil)"))
        XCTAssertFalse(active.contains("ZStack"))
        XCTAssertFalse(active.contains(".overlay"))
        XCTAssertFalse(accountRoot.contains("onGeometryChange"))
        XCTAssertFalse(accountRoot.contains("coordinateSpace"))
    }

    /// Mailbox assignment and per-mailbox notification policy are sheets, not
    /// panels layered over the mail.
    func testMailRootPresentsMailboxPanelsAsSheets() throws {
        let mailRoot = try source(at: "Apps/PlainpostiOS/Plainpost/MobileMailRootView.swift")
        let contentStart = try XCTUnwrap(mailRoot.range(of: "private var mailContent: some View {"))
        let contentEnd = try XCTUnwrap(mailRoot.range(of: "private var showsMailboxNotificationPolicy: Bool {", range: contentStart.upperBound..<mailRoot.endIndex))
        let content = mailRoot[contentStart.upperBound..<contentEnd.lowerBound]
        XCTAssertTrue(content.contains("mailboxAssignmentSheet"))
        XCTAssertTrue(content.contains("mailboxNotificationPolicySheet"))
        XCTAssertEqual(content.components(separatedBy: ".sheet(isPresented:").count - 1, 1)
        XCTAssertTrue(content.contains(".modifier(MailboxNotificationPolicySheetPresenter("))
        XCTAssertFalse(content.contains("ZStack"))
        XCTAssertFalse(mailRoot.contains("mailboxAssignmentPanel"))
        XCTAssertFalse(mailRoot.contains("mailboxNotificationPolicyPanel"))
    }

    private func source(at relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
