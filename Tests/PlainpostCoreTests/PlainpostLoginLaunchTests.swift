import Foundation
import XCTest
@testable import PlainpostCore

final class PlainpostLoginLaunchTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testLoginArgumentIsExact() {
        XCTAssertTrue(PlainpostLoginLaunch.isLoginLaunch(arguments: [
            "/Applications/Plainpost.app/Contents/MacOS/Plainpost", "--launched-at-login",
        ]))
        XCTAssertFalse(PlainpostLoginLaunch.isLoginLaunch(arguments: ["Plainpost", "--launched-at-login=1"]))
        XCTAssertFalse(PlainpostLoginLaunch.isLoginLaunch(arguments: ["Plainpost", "--Launched-At-Login"]))
        XCTAssertFalse(PlainpostLoginLaunch.isLoginLaunch(arguments: ["Plainpost"]))
        XCTAssertFalse(PlainpostLoginLaunch.isLoginLaunch(arguments: []))
        // argv[0] is the executable path, never a launch flag.
        XCTAssertFalse(PlainpostLoginLaunch.isLoginLaunch(arguments: ["--launched-at-login"]))
    }

    func testIdentifiersUseTheCurrentBundlePrefix() {
        XCTAssertEqual(PlainpostLoginLaunch.label, "com.marynavdovenko.Plainpost.LoginApp")
        XCTAssertEqual(PlainpostLoginLaunch.plistName, "com.marynavdovenko.Plainpost.LoginApp.plist")
        XCTAssertEqual(PlainpostLoginLaunch.argument, "--launched-at-login")
        XCTAssertEqual(PlainpostLoginLaunch.preferenceKey, "Plainpost.openAtLogin")
    }

    func testStartupDecisionYieldsToRunningInstanceAndRetiresWhenPreferenceIsOff() {
        let login = ["Plainpost", "--launched-at-login"]
        XCTAssertEqual(
            PlainpostLoginLaunch.startupDecision(arguments: login, otherInstanceRunning: false, openAtLogin: true),
            .run
        )
        // Registering the login item loads its RunAtLoad job at once; that
        // spawned copy must leave the already-running app alone.
        XCTAssertEqual(
            PlainpostLoginLaunch.startupDecision(arguments: login, otherInstanceRunning: true, openAtLogin: true),
            .yield
        )
        // A login launch after the user turned the preference off removes
        // its own registration (which ends this process) instead of running.
        XCTAssertEqual(
            PlainpostLoginLaunch.startupDecision(arguments: login, otherInstanceRunning: false, openAtLogin: false),
            .retire
        )
        XCTAssertEqual(
            PlainpostLoginLaunch.startupDecision(arguments: login, otherInstanceRunning: true, openAtLogin: false),
            .yield
        )
        // Manual launches are never affected.
        for other in [false, true] {
            for preference in [false, true] {
                XCTAssertEqual(
                    PlainpostLoginLaunch.startupDecision(
                        arguments: ["Plainpost"], otherInstanceRunning: other, openAtLogin: preference
                    ),
                    .run
                )
            }
        }
    }

    func testOpenAtLoginPreferenceDefaultsOn() throws {
        let suite = "PlainpostLoginLaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PlainpostLoginLaunch.openAtLogin(in: defaults))
        defaults.set(false, forKey: PlainpostLoginLaunch.preferenceKey)
        XCTAssertFalse(PlainpostLoginLaunch.openAtLogin(in: defaults))
        defaults.set(true, forKey: PlainpostLoginLaunch.preferenceKey)
        XCTAssertTrue(PlainpostLoginLaunch.openAtLogin(in: defaults))
    }

    func testRegistrarFollowsPreference() async throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .disabled)
        let registrar = fake.registrar(appBundleURL: bundle)

        let enabledStatus = await registrar.reconcile(enabled: true)
        XCTAssertEqual(enabledStatus, .enabled)
        let disabledStatus = await registrar.reconcile(enabled: false)
        XCTAssertEqual(disabledStatus, .disabled)
        let events = await fake.events
        XCTAssertEqual(events, ["register", "unregister"])
    }

    func testRegistrarDoesNotReRegisterAnEnabledLoginItem() async throws {
        // Registration loads the RunAtLoad job, which launches a second copy
        // of the app. An already-enabled item is left alone on every launch.
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .enabled)
        let registrar = fake.registrar(appBundleURL: bundle)

        let status = await registrar.reconcile(enabled: true)
        XCTAssertEqual(status, .enabled)
        let events = await fake.events
        XCTAssertEqual(events, [])
    }

    func testRegistrarReRegistersAnEnabledItemOnlyAfterTheBundleChanged() async throws {
        // SMAppService: an agent whose plist or executable changed must be
        // registered again or it may not launch. A reinstall is detected by
        // the bundle fingerprint, never by re-registering on every launch.
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .enabled)
        let stamp = StampStore(saved: "old-install")
        let registrar = fake.registrar(appBundleURL: bundle, stamp: stamp.stamp(current: "new-install"))

        let refreshed = await registrar.reconcile(enabled: true)
        XCTAssertEqual(refreshed, .enabled)
        var events = await fake.events
        XCTAssertEqual(events, ["unregister", "register"])
        XCTAssertEqual(stamp.saved, "new-install")

        let unchanged = await registrar.reconcile(enabled: true)
        XCTAssertEqual(unchanged, .enabled)
        events = await fake.events
        XCTAssertEqual(events, ["unregister", "register"])

        _ = await registrar.reconcile(enabled: false)
        XCTAssertNil(stamp.saved, "an unregistered item has no registered install")
    }

    func testRegistrarRecordsTheInstallItRegistered() async throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .disabled)
        let stamp = StampStore(saved: nil)
        let registrar = fake.registrar(appBundleURL: bundle, stamp: stamp.stamp(current: "install"))

        _ = await registrar.reconcile(enabled: true)
        XCTAssertEqual(stamp.saved, "install")

        let denied = LoginItemFake(status: .disabled, registerOutcome: .requiresApproval, registerThrows: true)
        let deniedStamp = StampStore(saved: nil)
        _ = await denied.registrar(appBundleURL: bundle, stamp: deniedStamp.stamp(current: "install"))
            .reconcile(enabled: true)
        XCTAssertNil(deniedStamp.saved, "a refused registration records nothing")
    }

    func testLoginLaunchNeverRefreshesItsOwnJob() async throws {
        // Unregistering would end this process, which launchd has just
        // started from the current bundle anyway.
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .enabled)
        let stamp = StampStore(saved: "old-install")
        let registrar = fake.registrar(
            appBundleURL: bundle,
            currentProcessIsLoginItem: true,
            stamp: stamp.stamp(current: "new-install")
        )

        let status = await registrar.reconcile(enabled: true)
        XCTAssertEqual(status, .enabled)
        let events = await fake.events
        XCTAssertEqual(events, [])
        XCTAssertEqual(stamp.saved, "old-install")
    }

    func testBundleFingerprintChangesWhenTheInstallChanges() throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let executable = bundle.appendingPathComponent("Contents/MacOS/Plainpost")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("build one".utf8).write(to: executable)
        let first = try XCTUnwrap(PlainpostLoginLaunch.bundleFingerprint(appBundleURL: bundle))
        XCTAssertEqual(PlainpostLoginLaunch.bundleFingerprint(appBundleURL: bundle), first)

        try Data("build two, replaced".utf8).write(to: executable)
        let second = try XCTUnwrap(PlainpostLoginLaunch.bundleFingerprint(appBundleURL: bundle))
        XCTAssertNotEqual(second, first)

        try Data("<plist><dict/></plist>".utf8).write(
            to: PlainpostLoginLaunch.bundledPlistURL(appBundleURL: bundle)
        )
        XCTAssertNotEqual(PlainpostLoginLaunch.bundleFingerprint(appBundleURL: bundle), second)
        XCTAssertNil(PlainpostLoginLaunch.bundleFingerprint(
            appBundleURL: bundle.deletingLastPathComponent().appendingPathComponent("Missing.app")
        ))
    }

    func testRegistrarLeavesApprovalToTheUser() async throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .requiresApproval)
        let registrar = fake.registrar(appBundleURL: bundle)

        let status = await registrar.reconcile(enabled: true)
        XCTAssertEqual(status, .requiresApproval)
        let events = await fake.events
        XCTAssertEqual(events, [])
    }

    func testRegistrarReportsApprovalWhenRegistrationIsDenied() async throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .disabled, registerOutcome: .requiresApproval, registerThrows: true)
        let registrar = fake.registrar(appBundleURL: bundle)

        let status = await registrar.reconcile(enabled: true)
        XCTAssertEqual(status, .requiresApproval)
        let events = await fake.events
        XCTAssertEqual(events, ["register"])
    }

    func testRegistrarDefersUnregisterWhileThisProcessIsTheLoginJob() async throws {
        // Unregistering the job that launched this process would end it.
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .enabled)
        let registrar = fake.registrar(appBundleURL: bundle, currentProcessIsLoginItem: true)

        let status = await registrar.reconcile(enabled: false)
        XCTAssertEqual(status, .enabledUntilQuit)
        let events = await fake.events
        XCTAssertEqual(events, [])

        let reEnabled = await registrar.reconcile(enabled: true)
        XCTAssertEqual(reEnabled, .enabled)
        let laterEvents = await fake.events
        XCTAssertEqual(laterEvents, [])
    }

    func testRegistrarNeverTouchesServiceManagementOutsideAPackagedApp() async throws {
        // A SwiftPM run has no .app bundle, and a bundle without the plist
        // has nothing to register.
        let swiftPMRoot = try makeRoot()
        let executableDirectory = swiftPMRoot.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let bundleWithoutPlist = try makePackagedBundleFixture(plists: [])
        let bundleWithOnlyServicePlist = try makePackagedBundleFixture(
            plists: [PlainpostPackagedServiceRestorer.bundledPlistName]
        )
        let symlinkedPlistBundle = try makePackagedBundleFixture(plists: [])
        let target = swiftPMRoot.appendingPathComponent("elsewhere.plist")
        try Data("plist".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: PlainpostLoginLaunch.bundledPlistURL(appBundleURL: symlinkedPlistBundle),
            withDestinationURL: target
        )
        let plistNamedNonApp = swiftPMRoot.appendingPathComponent("Plainpost", isDirectory: true)
        let fakePlist = PlainpostLoginLaunch.bundledPlistURL(appBundleURL: plistNamedNonApp)
        try FileManager.default.createDirectory(
            at: fakePlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plist".utf8).write(to: fakePlist)

        for bundle in [executableDirectory, bundleWithoutPlist, bundleWithOnlyServicePlist, symlinkedPlistBundle, plistNamedNonApp] {
            let fake = LoginItemFake(status: .disabled)
            let registrar = fake.registrar(appBundleURL: bundle)
            let enabled = await registrar.reconcile(enabled: true)
            XCTAssertEqual(enabled, .unavailable, bundle.path)
            let disabled = await registrar.reconcile(enabled: false)
            XCTAssertEqual(disabled, .unavailable, bundle.path)
            XCTAssertEqual(registrar.currentStatus(), .unavailable, bundle.path)
            let events = await fake.events
            XCTAssertEqual(events, [], bundle.path)
            let statusReads = await fake.statusReads
            XCTAssertEqual(statusReads, 0, bundle.path)
        }
    }

    func testRegistrarOnlyManagesAnInstalledCopy() async throws {
        // Acceptance bundles and dev builds under .build must never become
        // the login item: they would open at the next login and share the
        // installed app's label.
        let installed = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let applications = installed.deletingLastPathComponent()
        let buildOutput = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])

        let outside = LoginItemFake(status: .disabled)
        let outsideRegistrar = outside.registrar(appBundleURL: buildOutput, installedLocations: [applications])
        let outsideEnabled = await outsideRegistrar.reconcile(enabled: true)
        XCTAssertEqual(outsideEnabled, .unavailable)
        let outsideDisabled = await outsideRegistrar.reconcile(enabled: false)
        XCTAssertEqual(outsideDisabled, .unavailable)
        let outsideEvents = await outside.events
        XCTAssertEqual(outsideEvents, [])

        let inside = LoginItemFake(status: .disabled)
        let insideStatus = await inside.registrar(appBundleURL: installed, installedLocations: [applications])
            .reconcile(enabled: true)
        XCTAssertEqual(insideStatus, .enabled)
        let insideEvents = await inside.events
        XCTAssertEqual(insideEvents, ["register"])

        // A nested bundle inside an installed app is not an installed copy.
        let nested = installed.appendingPathComponent("Contents/Library/Plainpost.app", isDirectory: true)
        let nestedPlist = PlainpostLoginLaunch.bundledPlistURL(appBundleURL: nested)
        try FileManager.default.createDirectory(
            at: nestedPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<plist/>".utf8).write(to: nestedPlist)
        let nestedFake = LoginItemFake(status: .disabled)
        let nestedStatus = await nestedFake.registrar(appBundleURL: nested, installedLocations: [applications])
            .reconcile(enabled: true)
        XCTAssertEqual(nestedStatus, .unavailable)

        XCTAssertEqual(
            PlainpostLoginItemRegistrar.defaultInstalledLocations(home: URL(fileURLWithPath: "/Users/someone")).map(\.path),
            ["/Applications", "/Users/someone/Applications"]
        )
    }

    func testBundledAgentRefreshStillRegistersWhenUnregisterFails() async throws {
        // Packaging boots the job out before replacing the bundle. The stale
        // registration can then refuse to unregister; that must not skip the
        // register that loads the new job.
        let recorder = LoginItemEventRecorder()
        try await PlainpostBundledAgentRefresh.refresh(
            isEnabled: true,
            unregister: {
                await recorder.record("unregister")
                throw PlainpostError.validationFailed("job not loaded")
            },
            register: { await recorder.record("register") }
        )
        let events = await recorder.events
        XCTAssertEqual(events, ["unregister", "register"])
    }

    func testBundledAgentRefreshRegistersDirectlyWhenNotEnabledAndSurfacesRegisterFailure() async throws {
        let recorder = LoginItemEventRecorder()
        try await PlainpostBundledAgentRefresh.refresh(
            isEnabled: false,
            unregister: { await recorder.record("unregister") },
            register: { await recorder.record("register") }
        )
        let events = await recorder.events
        XCTAssertEqual(events, ["register"])

        do {
            try await PlainpostBundledAgentRefresh.refresh(
                isEnabled: true,
                unregister: {},
                register: { throw PlainpostError.validationFailed("denied") }
            )
            XCTFail("A failed register must reach the caller.")
        } catch {}
    }

    func testReinstallReRegistersAnItemWaitingForApproval() async throws {
        let bundle = try makePackagedBundleFixture(plists: [PlainpostLoginLaunch.plistName])
        let fake = LoginItemFake(status: .requiresApproval)
        let stamp = StampStore(saved: "old-install")
        let registrar = fake.registrar(appBundleURL: bundle, stamp: stamp.stamp(current: "new-install"))

        let status = await registrar.reconcile(enabled: true)
        XCTAssertEqual(status, .enabled)
        let events = await fake.events
        XCTAssertEqual(events, ["unregister", "register"])

        let same = LoginItemFake(status: .requiresApproval)
        let sameStamp = StampStore(saved: "install")
        let unchanged = await same.registrar(appBundleURL: bundle, stamp: sameStamp.stamp(current: "install"))
            .reconcile(enabled: true)
        XCTAssertEqual(unchanged, .requiresApproval)
        let sameEvents = await same.events
        XCTAssertEqual(sameEvents, [])
    }

    func testServiceBuildIdentityTracksPathAndBuild() throws {
        let root = try makeRoot()
        let app = root.appendingPathComponent("Plainpost.app", isDirectory: true)
        let service = app.appendingPathComponent("Contents/Library/Helpers/PlainpostService.app", isDirectory: true)
        try writeBundle(service, executable: "PlainpostService", version: "42", contents: "build one")

        let first = try XCTUnwrap(PlainpostServiceBuildIdentity.bundledService(appBundleURL: app))
        XCTAssertEqual(first.bundlePath, PlainpostServiceBuildIdentity.canonicalPath(service))
        XCTAssertEqual(PlainpostServiceBuildIdentity.of(bundleURL: service), first)

        try FileManager.default.removeItem(at: service.appendingPathComponent("Contents/MacOS/PlainpostService"))
        try Data("build two".utf8).write(to: service.appendingPathComponent("Contents/MacOS/PlainpostService"))
        let second = try XCTUnwrap(PlainpostServiceBuildIdentity.bundledService(appBundleURL: app))
        XCTAssertEqual(second.bundlePath, first.bundlePath)
        XCTAssertNotEqual(second.buildStamp, first.buildStamp, "a replaced executable is a different build")

        XCTAssertNil(PlainpostServiceBuildIdentity.of(bundleURL: root.appendingPathComponent(".build/debug")))
        XCTAssertNil(PlainpostServiceBuildIdentity.bundledService(appBundleURL: root.appendingPathComponent("Missing.app")))
    }

    func testOwnershipComparesTheServiceBundlePath() {
        let own = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/Contents/Library/Helpers/PlainpostService.app", buildStamp: "1")
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Users/me/Plainpost.app/Contents/Library/Helpers/PlainpostService.app", buildStamp: "1")
        let olderOwn = PlainpostServiceBuildIdentity(bundlePath: own.bundlePath, buildStamp: "0")
        XCTAssertEqual(PlainpostServiceOwnership.evaluate(reported: own, expected: own), .own)
        XCTAssertEqual(PlainpostServiceOwnership.evaluate(reported: olderOwn, expected: own), .own)
        XCTAssertEqual(PlainpostServiceOwnership.evaluate(reported: foreign, expected: own), .foreign(bundlePath: foreign.bundlePath))
        XCTAssertEqual(PlainpostServiceOwnership.evaluate(reported: nil, expected: own), .unknown)
        XCTAssertEqual(PlainpostServiceOwnership.evaluate(reported: own, expected: nil), .unknown)
    }

    func testBundledServiceIsBouncedOnlyWhenMissingUnloadedOrStale() {
        typealias Policy = PlainpostBundledServiceRefreshPolicy
        let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "new")
        let running = PlainpostServiceBuildIdentity(bundlePath: expected.bundlePath, buildStamp: "new")
        let stale = PlainpostServiceBuildIdentity(bundlePath: expected.bundlePath, buildStamp: "old")
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Other/Plainpost.app/S.app", buildStamp: "new")

        // The running service is this build: leave it (and its mirror) alone.
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .identity(running), expected: expected), .keepRunning)
        // Replaced files, a job that is not loaded, an older service that
        // cannot answer, or no registration: reload.
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .identity(stale), expected: expected), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .unreachable, expected: expected), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .unidentified, expected: expected), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: false, reported: .unreachable, expected: expected), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: false, reported: .identity(running), expected: expected), .refresh)
        // Without its own identity the app cannot compare: old behaviour.
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .identity(running), expected: nil), .refresh)
        // Another installation's service is never bounced from here.
        XCTAssertEqual(
            Policy.decide(isRegistered: true, reported: .identity(foreign), expected: expected, bundleIsGone: { _ in false }),
            .foreign(bundlePath: foreign.bundlePath)
        )
        XCTAssertEqual(
            Policy.decide(isRegistered: false, reported: .identity(foreign), expected: expected, bundleIsGone: { _ in false }),
            .foreign(bundlePath: foreign.bundlePath)
        )
    }

    func testInstanceLockAdmitsOneHolderAtATime() throws {
        let url = try makeRoot().appendingPathComponent("Plainpost/app-instance.lock")
        var first = PlainpostInstanceLock.acquire(at: url)
        XCTAssertNotNil(first)
        // flock is per open file description, so a second open in this
        // process contends exactly like a second process would.
        XCTAssertNil(PlainpostInstanceLock.acquire(at: url))
        first = nil
        XCTAssertNotNil(PlainpostInstanceLock.acquire(at: url))
    }

    private func writeBundle(_ bundle: URL, executable: String, version: String, contents: String) throws {
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": executable, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data(contents.utf8).write(to: macOS.appendingPathComponent(executable))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostLoginLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makePackagedBundleFixture(plists: [String]) throws -> URL {
        let bundle = try makeRoot().appendingPathComponent("Plainpost.app", isDirectory: true)
        let agents = bundle.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for plist in plists {
            try Data("<plist/>".utf8).write(to: agents.appendingPathComponent(plist))
        }
        return bundle
    }
}

final class StampStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(saved: String?) { value = saved }

    var saved: String? { lock.withLock { value } }

    func stamp(current: String) -> PlainpostLoginItemRegistrar.RegistrationStamp {
        PlainpostLoginItemRegistrar.RegistrationStamp(
            current: { current },
            load: { [self] in lock.withLock { value } },
            save: { [self] newValue in lock.withLock { value = newValue } }
        )
    }
}

actor LoginItemEventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// A stateful stand-in for `SMAppService`: register and unregister move the
/// reported status the way the system does.
final class LoginItemFake: @unchecked Sendable {
    private let lock = NSLock()
    private var status: PlainpostLoginItemRegistrar.Status
    private var reads = 0
    private var recorded: [String] = []
    private let registerOutcome: PlainpostLoginItemRegistrar.Status
    private let registerThrows: Bool

    init(
        status: PlainpostLoginItemRegistrar.Status,
        registerOutcome: PlainpostLoginItemRegistrar.Status = .enabled,
        registerThrows: Bool = false
    ) {
        self.status = status
        self.registerOutcome = registerOutcome
        self.registerThrows = registerThrows
    }

    var events: [String] { get async { lock.withLock { recorded } } }
    var statusReads: Int { get async { lock.withLock { reads } } }

    func registrar(
        appBundleURL: URL,
        currentProcessIsLoginItem: Bool = false,
        stamp: PlainpostLoginItemRegistrar.RegistrationStamp? = nil,
        installedLocations: [URL]? = nil
    ) -> PlainpostLoginItemRegistrar {
        PlainpostLoginItemRegistrar(
            appBundleURL: appBundleURL,
            installedLocations: installedLocations,
            currentProcessIsLoginItem: currentProcessIsLoginItem,
            registrationStamp: stamp,
            register: { [self] in
                let fails = lock.withLock { () -> Bool in
                    recorded.append("register")
                    status = registerOutcome
                    return registerThrows
                }
                if fails { throw PlainpostError.validationFailed("Operation not permitted") }
            },
            unregister: { [self] in
                lock.withLock {
                    recorded.append("unregister")
                    status = .disabled
                }
            },
            status: { [self] in
                lock.withLock {
                    reads += 1
                    return status
                }
            }
        )
    }
}

final class PlainpostBundlePresenceTests: XCTestCase {
    func testOnlyAMissingPathCountsAsGone() {
        let path = "/Users/me/Documents/Plainpost.app/Contents/Library/Helpers/PlainpostService.app"
        XCTAssertFalse(PlainpostBundlePresence.isGone(path: path, statError: { _ in nil }))
        XCTAssertTrue(PlainpostBundlePresence.isGone(path: path, statError: { _ in ENOENT }))
        XCTAssertTrue(PlainpostBundlePresence.isGone(path: path, statError: { _ in ENOTDIR }))
        // A privacy (TCC) denial, an unreadable folder or a network-mount
        // error says nothing about whether the installation still exists.
        for error in [EACCES, EPERM, EIO, ETIMEDOUT, ESTALE] {
            XCTAssertFalse(PlainpostBundlePresence.isGone(path: path, statError: { _ in error }), "errno \(error)")
        }
    }

    func testAMissingPathOnAVolumeIsGoneOnlyOnceTheVolumeIsUnmounted() {
        let path = "/Volumes/External/Plainpost.app/Contents/Library/Helpers/PlainpostService.app"
        var asked: [String] = []
        XCTAssertFalse(PlainpostBundlePresence.isGone(path: path, statError: { _ in ENOENT }, isMounted: { asked.append($0); return true }))
        XCTAssertEqual(asked, ["/Volumes/External"])
        XCTAssertTrue(PlainpostBundlePresence.isGone(path: path, statError: { _ in ENOENT }, isMounted: { _ in false }))
    }

    func testRealFileSystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlainpostPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(PlainpostBundlePresence.isGone(path: root.path))
        XCTAssertTrue(PlainpostBundlePresence.isGone(path: root.appendingPathComponent("Deleted.app").path))
        XCTAssertTrue(PlainpostBundlePresence.isMountPoint("/"))
        XCTAssertFalse(PlainpostBundlePresence.isMountPoint(root.path))
    }

    func testUnreadableForeignInstallationStaysForeign() {
        let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "1")
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Users/me/Desktop/Plainpost.app/S.app", buildStamp: "1")
        let denied = PlainpostBundledServiceRefreshPolicy.decide(
            isRegistered: true, reported: .identity(foreign), expected: expected,
            bundleIsGone: { PlainpostBundlePresence.isGone(path: $0, statError: { _ in EACCES }) }
        )
        XCTAssertEqual(denied, .foreign(bundlePath: foreign.bundlePath))
        let deleted = PlainpostBundledServiceRefreshPolicy.decide(
            isRegistered: true, reported: .identity(foreign), expected: expected,
            bundleIsGone: { PlainpostBundlePresence.isGone(path: $0, statError: { _ in ENOENT }) }
        )
        XCTAssertEqual(deleted, .refresh)
    }

    func testBusyServiceIsRestartedAfterThreeChecksOrFiveMinutes() {
        typealias Policy = PlainpostBundledServiceRefreshPolicy
        let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "1")
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .busy, expected: expected, consecutiveBusyChecks: 1), .keepRunning)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .busy, expected: expected, consecutiveBusyChecks: 2, busyDuration: 299), .keepRunning)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .busy, expected: expected, consecutiveBusyChecks: 3), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .busy, expected: expected, consecutiveBusyChecks: 2, busyDuration: 300), .refresh)
    }

    func testBusyTrackerCountsOnlyAnUnbrokenStreak() {
        let tracker = PlainpostServiceBusyTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(tracker.record(.busy, now: start).count, 1)
        let second = tracker.record(.busy, now: start.addingTimeInterval(40))
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.duration, 40)
        XCTAssertEqual(tracker.record(.unreachable, now: start.addingTimeInterval(50)).count, 0)
        XCTAssertEqual(tracker.record(.busy, now: start.addingTimeInterval(60)).count, 1)
        tracker.reset()
        XCTAssertEqual(tracker.record(.busy, now: start.addingTimeInterval(70)).duration, 0)
    }
}
