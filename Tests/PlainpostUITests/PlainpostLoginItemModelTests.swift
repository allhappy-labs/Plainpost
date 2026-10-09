import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class PlainpostLoginItemModelTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        roots = []
        suites = []
        try await super.tearDown()
    }

    func testPreferenceDefaultsOnAndRegistersThePackagedLoginItem() async throws {
        let store = LoginItemStore(status: .disabled)
        let model = try makeModel(store: store)
        XCTAssertTrue(model.isEnabled)

        await model.reconcile()

        XCTAssertEqual(model.status, .enabled)
        XCTAssertEqual(store.events, ["register"])
    }

    func testTurningThePreferenceOffPersistsAndUnregisters() async throws {
        let store = LoginItemStore(status: .enabled)
        let defaults = try makeDefaults()
        let model = try makeModel(store: store, defaults: defaults)

        await model.setEnabled(false)

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(defaults.object(forKey: PlainpostLoginLaunch.preferenceKey) as? Bool, false)
        XCTAssertEqual(model.status, .disabled)
        XCTAssertEqual(store.events, ["unregister"])

        await model.setEnabled(true)
        XCTAssertEqual(defaults.object(forKey: PlainpostLoginLaunch.preferenceKey) as? Bool, true)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertEqual(store.events, ["unregister", "register"])
    }

    func testRapidTogglesApplyInOrder() async throws {
        let store = LoginItemStore(status: .disabled)
        let model = try makeModel(store: store)

        let first = Task { @MainActor in await model.setEnabled(false) }
        let second = Task { @MainActor in await model.setEnabled(true) }
        await first.value
        await second.value

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertEqual(store.events.last, "register")
    }

    func testRequiresApprovalShowsTheSystemSettingsHintAndButton() async throws {
        let store = LoginItemStore(status: .requiresApproval)
        var openedSettings = 0
        let model = try makeModel(store: store, openLoginItemsSettings: { openedSettings += 1 })
        await model.reconcile()

        let presentation = model.presentation
        XCTAssertEqual(presentation.hint, "Allow Plainpost in System Settings → General → Login Items")
        XCTAssertTrue(presentation.showsLoginItemsSettingsButton)
        XCTAssertTrue(presentation.isToggleEnabled)
        model.openLoginItemsSettings()
        XCTAssertEqual(openedSettings, 1)
    }

    func testPresentationForEveryStatus() {
        let enabled = PlainpostLoginItemPresentation(status: .enabled, isEnabled: true)
        XCTAssertNil(enabled.hint)
        XCTAssertFalse(enabled.showsLoginItemsSettingsButton)
        XCTAssertTrue(enabled.isToggleEnabled)

        let unavailable = PlainpostLoginItemPresentation(status: .unavailable, isEnabled: true)
        XCTAssertFalse(unavailable.isToggleEnabled)
        XCTAssertEqual(unavailable.hint, "Available in the installed Plainpost app.")
        XCTAssertFalse(unavailable.showsLoginItemsSettingsButton)

        let pending = PlainpostLoginItemPresentation(status: .enabledUntilQuit, isEnabled: false)
        XCTAssertEqual(pending.hint, "Plainpost removes itself from Login Items the next time it opens at login.")
        XCTAssertTrue(pending.isToggleEnabled)

        // The approval hint only matters while the user wants the item.
        let offAwaitingApproval = PlainpostLoginItemPresentation(status: .requiresApproval, isEnabled: false)
        XCTAssertNil(offAwaitingApproval.hint)
        XCTAssertFalse(offAwaitingApproval.showsLoginItemsSettingsButton)
    }

    func testUnpackagedRunNeverRegisters() async throws {
        let store = LoginItemStore(status: .disabled)
        let executableDirectory = try makeRoot().appendingPathComponent(".build/debug", isDirectory: true)
        let model = PlainpostLoginItemModel(
            registrar: store.registrar(appBundleURL: executableDirectory),
            defaults: try makeDefaults(),
            openLoginItemsSettings: {}
        )

        await model.reconcile()
        await model.setEnabled(false)
        await model.setEnabled(true)

        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(store.events, [])
        XCTAssertFalse(model.presentation.isToggleEnabled)
    }

    private func makeModel(
        store: LoginItemStore,
        defaults: UserDefaults? = nil,
        openLoginItemsSettings: @escaping @MainActor () -> Void = {}
    ) throws -> PlainpostLoginItemModel {
        let bundle = try makeRoot().appendingPathComponent("Plainpost.app", isDirectory: true)
        let plist = PlainpostLoginLaunch.bundledPlistURL(appBundleURL: bundle)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: plist)
        return PlainpostLoginItemModel(
            registrar: store.registrar(appBundleURL: bundle),
            defaults: try defaults ?? makeDefaults(),
            openLoginItemsSettings: openLoginItemsSettings
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostLoginItemModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "PlainpostLoginItemModelTests-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
}

private final class LoginItemStore: @unchecked Sendable {
    private let lock = NSLock()
    private var status: PlainpostLoginItemRegistrar.Status
    private var recorded: [String] = []

    init(status: PlainpostLoginItemRegistrar.Status) { self.status = status }

    var events: [String] { lock.withLock { recorded } }

    func registrar(appBundleURL: URL) -> PlainpostLoginItemRegistrar {
        PlainpostLoginItemRegistrar(
            appBundleURL: appBundleURL,
            register: { [self] in
                lock.withLock {
                    recorded.append("register")
                    status = .enabled
                }
            },
            unregister: { [self] in
                lock.withLock {
                    recorded.append("unregister")
                    status = .disabled
                }
            },
            status: { [self] in lock.withLock { status } }
        )
    }
}
