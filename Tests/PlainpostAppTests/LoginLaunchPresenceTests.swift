import AppKit
import XCTest
@testable import PlainpostApp

@MainActor
final class LoginLaunchPresenceTests: XCTestCase {
    func testLoginLaunchStaysHiddenAndLastWindowCloseKeepsAppRunning() {
        let presence = PresenceRecorder(hasUserFacingWindow: false)
        var openedMailbox = 0
        let delegate = PlainpostApplicationDelegate(
            presenceController: presence.controller,
            launchArguments: ["Plainpost", "--launched-at-login"],
            openMailbox: { openedMailbox += 1 },
            initialWindowCheckDelay: .zero
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(presence.policies, [.accessory])
        XCTAssertEqual(openedMailbox, 0)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertFalse(PlainpostApplicationDelegate.presentsMailboxAtLaunch(arguments: ["Plainpost", "--launched-at-login"]))
    }

    func testManualLaunchStillOpensTheMailboxWindow() {
        let presence = PresenceRecorder(hasUserFacingWindow: false)
        let opened = expectation(description: "mailbox window opened")
        let delegate = PlainpostApplicationDelegate(
            presenceController: presence.controller,
            launchArguments: ["Plainpost"],
            openMailbox: { opened.fulfill() },
            initialWindowCheckDelay: .zero
        )

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        wait(for: [opened], timeout: 5)
        XCTAssertEqual(presence.policies.first, .regular)
        XCTAssertFalse(presence.policies.contains(.accessory))
        XCTAssertTrue(PlainpostApplicationDelegate.presentsMailboxAtLaunch(arguments: ["Plainpost"]))
    }

    func testManualLaunchDoesNotOpenASecondWindow() {
        let presence = PresenceRecorder(hasUserFacingWindow: true)
        var openedMailbox = 0
        let delegate = PlainpostApplicationDelegate(
            presenceController: presence.controller,
            launchArguments: ["Plainpost"],
            openMailbox: { openedMailbox += 1 },
            initialWindowCheckDelay: .zero
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(openedMailbox, 0)
    }

    func testReopenAfterHiddenLaunchPresentsTheWindow() {
        let presence = PresenceRecorder(hasUserFacingWindow: false)
        let delegate = PlainpostApplicationDelegate(
            presenceController: presence.controller,
            launchArguments: ["Plainpost", "--launched-at-login"],
            openMailbox: {},
            initialWindowCheckDelay: .zero
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        XCTAssertTrue(handled, "SwiftUI reopens its default mailbox scene")
        XCTAssertEqual(presence.policies, [.accessory, .regular])
        XCTAssertEqual(presence.activations, 1)
    }
}

@MainActor
private final class PresenceRecorder {
    var policies: [NSApplication.ActivationPolicy] = []
    var activations = 0
    private let hasUserFacingWindow: Bool
    lazy var controller = PlainpostApplicationPresenceController(
        currentActivationPolicy: { [unowned self] in policies.last ?? .prohibited },
        setActivationPolicy: { [unowned self] in policies.append($0) },
        hasUserFacingWindow: { [unowned self] in hasUserFacingWindow },
        activateAfterPresentation: { [unowned self] in activations += 1 }
    )

    init(hasUserFacingWindow: Bool) { self.hasUserFacingWindow = hasUserFacingWindow }
}
