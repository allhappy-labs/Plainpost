import AppKit
import UserNotifications
import XCTest
import PlainpostUI
@testable import PlainpostApp

@MainActor
final class PlainpostApplicationDelegateTests: XCTestCase {
    func testOnlyMainMailboxWindowHidesItsNativeTitle() {
        XCTAssertFalse(PlainpostWindowToolbarConfiguration.mailboxShowsTitle)
        XCTAssertTrue(PlainpostWindowToolbarConfiguration.composeShowsTitle)
        XCTAssertTrue(PlainpostWindowToolbarConfiguration.settingsShowsTitle)
    }

    func testMailboxUIAcceptanceIsInertUnlessExactDebugFlagIsPresent() throws {
        XCTAssertFalse(
            try PlainpostDebugMailboxUIAcceptance.resolve(
                environment: [:],
                syncAcceptanceConfigured: false
            )
        )
        XCTAssertTrue(
            try PlainpostDebugMailboxUIAcceptance.resolve(
                environment: ["PLAINPOST_MAILBOX_UI_ACCEPTANCE": "1"],
                syncAcceptanceConfigured: false
            )
        )
    }

    func testMailboxUIAcceptanceRejectsInvalidAndConflictingConfiguration() {
        XCTAssertThrowsError(
            try PlainpostDebugMailboxUIAcceptance.resolve(
                environment: ["PLAINPOST_MAILBOX_UI_ACCEPTANCE": "true"],
                syncAcceptanceConfigured: false
            )
        ) { error in
            XCTAssertEqual(
                error as? PlainpostDebugMailboxUIAcceptance.Error,
                .invalidValue
            )
        }
        XCTAssertThrowsError(
            try PlainpostDebugMailboxUIAcceptance.resolve(
                environment: ["PLAINPOST_MAILBOX_UI_ACCEPTANCE": "1"],
                syncAcceptanceConfigured: true
            )
        ) { error in
            XCTAssertEqual(
                error as? PlainpostDebugMailboxUIAcceptance.Error,
                .conflictsWithSyncAcceptance
            )
        }
    }

    func testMailboxScrollProfileUsesDeterministicMailboxFixture() throws {
        let environment = [
            PlainpostDebugMailboxUIAcceptance.environmentKey: "1",
            PlainpostDebugMailboxScrollProfile.environmentKey: "1",
        ]

        XCTAssertTrue(
            try PlainpostDebugMailboxScrollProfile.resolve(environment: environment)
        )
    }

    func testMailboxUIAcceptanceApplicationModelDoesNotStartRuntime() {
        let model = PlainpostApplicationModel.debugMailboxUIAcceptance()

        XCTAssertNil(model.runtime)
        XCTAssertNil(model.runtimeError)
        XCTAssertEqual(model.vaultLaunchState, .checking)
        XCTAssertEqual(
            PlainpostDebugMailboxUIAcceptance.composerPresentationPolicy,
            .snapshotWindow
        )
    }

    func testMailboxUIAcceptanceForcesFocusedModeDespitePersistedPreference() throws {
        let defaults = UserDefaults.standard
        let key = "Plainpost.inbox.displayMode"
        let priorValue = defaults.object(forKey: key)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        for persistedMode in [
            InboxDisplayMode.simpleList,
            .unreadCards,
        ] {
            defaults.set(
                persistedMode.rawValue,
                forKey: key
            )

            XCTAssertEqual(
                PlainpostDebugMailboxUIAcceptance.initialInboxMode,
                .focusedList
            )
            XCTAssertNil(
                PlainpostDebugMailboxUIAcceptance.initialSmartInboxBundle
            )
        }
    }

    func testDebugAcceptancePresentationDependenciesDoNotConstructSystemModels() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("plainpost-acceptance.\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        var systemContactCreations = 0
        var systemIconCreations = 0

        let dependencies = try PlainpostApplicationPresentationDependencies.debugAcceptance(
            rootURL: root,
            makeSystemContacts: {
                systemContactCreations += 1
                return .system()
            },
            makeSystemSiteIcons: {
                systemIconCreations += 1
                return .system()
            }
        )

        XCTAssertEqual(systemContactCreations, 0)
        XCTAssertEqual(systemIconCreations, 0)
        await dependencies.contactDirectory.prepare()
    }

    func testDebugWindowlessAcceptanceClosesWindowsBeforeStatus() async throws {
        var windowCount = 2
        var events: [String] = []

        try await PlainpostDebugWindowlessAcceptance.perform(
            closeUserFacingWindows: {
                events.append("close")
                windowCount = 0
            },
            userFacingWindowCount: { windowCount },
            setAccessoryPolicy: { events.append("accessory") },
            writeStatus: { events.append("status") }
        )

        XCTAssertEqual(events, ["close", "accessory", "status"])
    }

    func testDebugAcceptanceCanKeepWindowForGuardedVisualVerification() {
        XCTAssertTrue(PlainpostDebugWindowlessAcceptance.shouldConfigure(environment: [:]))
        XCTAssertFalse(
            PlainpostDebugWindowlessAcceptance.shouldConfigure(
                environment: ["PLAINPOST_ACCEPTANCE_MODE": "smart-inbox"]
            )
        )
    }



    func testClosingTheLastWindowDoesNotTerminateTheApplication() {
        let delegate = PlainpostApplicationDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }

    func testFinishingLaunchPromotesBeforeDefaultScenePresentation() {
        let harness = PresenceControllerHarness(
            activationPolicy: .accessory,
            hasUserFacingWindow: true
        )
        let delegate = PlainpostApplicationDelegate(presenceController: harness.controller)

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertEqual(harness.activationPolicy, .regular)
        XCTAssertEqual(harness.policyChanges, [.regular])
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    func testFinishingLaunchInstallsNotificationDelegate() {
        let harness = PresenceControllerHarness(
            activationPolicy: .regular,
            hasUserFacingWindow: true
        )
        var installedDelegate: (any UNUserNotificationCenterDelegate)?
        let delegate = PlainpostApplicationDelegate(
            presenceController: harness.controller,
            installNotificationDelegate: { installedDelegate = $0 }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertTrue((installedDelegate as AnyObject?) === delegate)
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    func testNotificationTokenQueuesUntilApplicationHandlerExists() {
        let harness = PresenceControllerHarness(
            activationPolicy: .regular,
            hasUserFacingWindow: true
        )
        let delegate = PlainpostApplicationDelegate(
            presenceController: harness.controller
        )
        var tokens: [String] = []

        delegate.handleNotificationOpenToken("opaque-token")
        XCTAssertTrue(tokens.isEmpty)
        delegate.setNotificationOpenHandler { tokens.append($0) }

        XCTAssertEqual(tokens, ["opaque-token"])
    }

    func testUnsafeNotificationTokenIsNotForwarded() {
        let harness = PresenceControllerHarness(
            activationPolicy: .regular,
            hasUserFacingWindow: true
        )
        let delegate = PlainpostApplicationDelegate(
            presenceController: harness.controller
        )
        var tokens: [String] = []
        delegate.setNotificationOpenHandler { tokens.append($0) }

        delegate.handleNotificationOpenToken("unsafe\ntoken")

        XCTAssertTrue(tokens.isEmpty)
    }

    func testReconcileUsesAccessoryPolicyWithoutUserFacingWindows() {
        let harness = PresenceControllerHarness(
            activationPolicy: .regular,
            hasUserFacingWindow: false
        )

        harness.controller.reconcileActivationPolicy()

        XCTAssertEqual(harness.activationPolicy, .accessory)
        XCTAssertEqual(harness.policyChanges, [.accessory])
    }

    func testReconcileUsesRegularPolicyWithAUserFacingWindow() {
        let harness = PresenceControllerHarness(
            activationPolicy: .accessory,
            hasUserFacingWindow: true
        )

        harness.controller.reconcileActivationPolicy()

        XCTAssertEqual(harness.activationPolicy, .regular)
        XCTAssertEqual(harness.policyChanges, [.regular])
    }

    func testReconcileDoesNotResetAnAlreadyCorrectPolicy() {
        let harness = PresenceControllerHarness(
            activationPolicy: .accessory,
            hasUserFacingWindow: false
        )

        harness.controller.reconcileActivationPolicy()

        XCTAssertTrue(harness.policyChanges.isEmpty)
    }

    func testPresentWindowPromotesBeforeOpeningAndActivatesAfterward() {
        let harness = PresenceControllerHarness(
            activationPolicy: .accessory,
            hasUserFacingWindow: false
        )

        harness.controller.presentWindow {
            harness.events.append("open")
        }

        XCTAssertEqual(harness.activationPolicy, .regular)
        XCTAssertEqual(harness.events, ["policy:regular", "open", "activate"])
    }
}

@MainActor
private final class PresenceControllerHarness {
    var activationPolicy: NSApplication.ActivationPolicy
    var events: [String] = []
    var policyChanges: [NSApplication.ActivationPolicy] = []
    private let hasUserFacingWindow: Bool

    lazy var controller = PlainpostApplicationPresenceController(
        currentActivationPolicy: { [unowned self] in
            activationPolicy
        },
        setActivationPolicy: { [unowned self] policy in
            activationPolicy = policy
            policyChanges.append(policy)
            events.append("policy:\(Self.name(for: policy))")
        },
        hasUserFacingWindow: { [unowned self] in
            hasUserFacingWindow
        },
        activateAfterPresentation: { [unowned self] in
            events.append("activate")
        }
    )

    init(
        activationPolicy: NSApplication.ActivationPolicy,
        hasUserFacingWindow: Bool
    ) {
        self.activationPolicy = activationPolicy
        self.hasUserFacingWindow = hasUserFacingWindow
    }

    private static func name(for policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
    }
}
