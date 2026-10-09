import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
import PlainpostNodeTransport
@testable import PlainpostUI
#if os(macOS)
import AppKit
import SwiftUI
#endif

final class AccountSecurityPresentationTests: XCTestCase {
    // A device name saves when the edit ends however it ends, but an untouched
    // field (or one already saved by Return) never saves again.
    func testDeviceLabelSavesOnlyWhenChanged() {
        XCTAssertEqual(AccountSecurityPresentation.deviceLabelToSave("Work Mac", lastSaved: "Mac"), "Work Mac")
        XCTAssertEqual(AccountSecurityPresentation.deviceLabelToSave("", lastSaved: "Mac"), "")
        XCTAssertNil(AccountSecurityPresentation.deviceLabelToSave("Mac", lastSaved: "Mac"))
    }

    func testEventTitlesAreReadable() {
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.deviceAdded), "New device added")
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.deviceRevoked), "Device revoked")
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.deviceSuspended), "Device suspended")
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.accountRecovered), "Account recovered")
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.accountDeleted), "Account deleted")
        XCTAssertEqual(AccountSecurityPresentation.eventTitle(.cleanupAcknowledged), "Device cleanup finished")
    }

    func testStatusesAndDatesHaveNoRawValues() {
        XCTAssertEqual(AccountSecurityPresentation.deviceStatus("active"), "Active")
        XCTAssertEqual(AccountSecurityPresentation.deviceStatus("suspended"), "Suspended")
        XCTAssertEqual(AccountSecurityPresentation.deviceStatus("revoked"), "Revoked")
        XCTAssertEqual(AccountSecurityPresentation.deviceStatus("pending"), "Pending")
        XCTAssertEqual(AccountSecurityPresentation.deviceStatus("erasure_pending"), "Needs attention")
        let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        let rel = AccountSecurityPresentation.relative("2026-10-02T10:00:00Z", now: now)
        XCTAssertNotNil(rel)
        XCTAssertFalse(rel!.contains("2026"))
        XCTAssertNotNil(AccountSecurityPresentation.relative("2026-10-02T10:00:00.250Z", now: now), "fractional seconds parse too")
        XCTAssertNil(AccountSecurityPresentation.relative("not a date", now: now))
        XCTAssertNil(AccountSecurityPresentation.relative(nil, now: now))
        XCTAssertEqual(AccountSecurityPresentation.host("https://sync.example.com:18443/"), "sync.example.com")
        XCTAssertNil(AccountSecurityPresentation.host(nil))
    }

    @MainActor
    func testDeviceNamesPreferTheLocalLabelThenAReadablePlatform() throws {
        let id = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(AccountSecurityPresentation.deviceName(.init(id: id, platform: .macos, isCurrentDevice: false, localLabel: "Ada's Mac")), "Ada's Mac")
        XCTAssertEqual(AccountSecurityPresentation.deviceName(.init(id: id, platform: .macos, isCurrentDevice: true)), "This Mac")
        XCTAssertEqual(AccountSecurityPresentation.deviceName(.init(id: id, platform: .macos, isCurrentDevice: false)), "Mac")
        XCTAssertEqual(AccountSecurityPresentation.deviceName(.init(id: id, platform: .ios, isCurrentDevice: false, localLabel: "")), "iPhone or iPad")
        XCTAssertEqual(AccountSecurityPresentation.deviceName(.init(id: id, platform: .syncNode, isCurrentDevice: false)), "Sync Node")
    }

    // The tag says which device is this one only when a custom name hid that.
    @MainActor
    func testDeviceRowTagMarksOnlyARenamedCurrentDevice() throws {
        let id = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .macos, isCurrentDevice: true, localLabel: "Work Mac")), "This Mac")
        XCTAssertEqual(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .ios, isCurrentDevice: true, localLabel: "Ada's phone")), "This iPhone or iPad", "macOS test host; iOS says This iPhone or This iPad")
        XCTAssertNil(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .macos, isCurrentDevice: true)), "the name already says This Mac")
        XCTAssertNil(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .macos, isCurrentDevice: true, localLabel: "")))
        XCTAssertNil(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .macos, isCurrentDevice: false, localLabel: "Work Mac")))
        XCTAssertNil(AccountSecurityPresentation.deviceTag(.init(id: id, platform: .syncNode, isCurrentDevice: true, localLabel: "Node")))
    }

    func testDeviceRowDetailIsStatusThenLastActivity() throws {
        let id = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        let recent = AccountLifecycleDeviceSummary(
            id: id, platform: .ios, isCurrentDevice: false, status: "suspended", lastSecurityEventAt: "2026-10-02T10:00:00Z"
        )
        let relative = try XCTUnwrap(AccountSecurityPresentation.relative("2026-10-02T10:00:00Z", now: now))
        XCTAssertEqual(AccountSecurityPresentation.deviceDetail(recent, now: now), "Suspended · Last activity \(relative)")
        XCTAssertEqual(AccountSecurityPresentation.deviceDetail(.init(id: id, platform: .macos, isCurrentDevice: true), now: now), "Active")
        XCTAssertEqual(
            AccountSecurityPresentation.deviceDetail(.init(id: id, platform: .macos, isCurrentDevice: false, status: "erasure_pending", lastSecurityEventAt: "not a date"), now: now),
            "Needs attention"
        )
        XCTAssertEqual(AccountSecurityPresentation.deviceSymbol(.macos), "desktopcomputer")
        XCTAssertEqual(AccountSecurityPresentation.deviceSymbol(.ios), "iphone")
        XCTAssertEqual(AccountSecurityPresentation.deviceSymbol(.syncNode), "server.rack")
    }

    func testNodeAccountFooterExplainsWhoSignsIn() {
        XCTAssertEqual(NodeAccountSettingsPage.footer(.ready), "Your Sync Node signs in to this account and keeps it synced.")
        XCTAssertEqual(
            NodeAccountSettingsPage.footer(.authenticationRequired),
            "Your Sync Node can't sign in to this account, so it isn't syncing."
        )
        XCTAssertEqual(NodeAccountSettingsPage.status(.authenticationRequired), "Needs attention")
    }

    // Values match what the runtime publishes (`PlainpostAppRuntime.makeNodeSettingsViewModel`
    // and the Node's status diagnostics): reachability "reachable", lag "<seconds>s", and
    // "Unavailable"/"unknown" when the status can't be read.
    func testSyncNodeConnectionSummary() {
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "0s"), "Connected")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "899s"), "Connected")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "unknown"), "Connected")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "Unavailable", syncLag: "Unavailable"), "Needs attention")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "unreachable", syncLag: "0s"), "Needs attention")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "2700s"), "Sync delayed")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "15m"), "Sync delayed")
        XCTAssertEqual(SyncNodeStatusText.connection(reachability: "reachable", syncLag: "2h"), "Sync delayed")
    }

    // Fails closed: anything but an explicit "reachable" needs attention.
    func testSyncNodeConnectionFailsClosed() {
        for placeholder in ["unknown", "Unknown", "Unavailable", "", "managed"] {
            XCTAssertEqual(SyncNodeStatusText.connection(reachability: placeholder, syncLag: "0s"), "Needs attention", placeholder)
        }
    }

    @MainActor
    func testSyncNodeStatusIsUnknownUntilTheFirstRead() {
        let placeholder = SyncNodeSettingsViewModel()
        XCTAssertFalse(placeholder.hasStatus, "the empty snapshot is a placeholder, not health")
        placeholder.update(SyncNodeSettingsSnapshot(
            version: "1", reachability: "reachable", syncLag: "0s", storage: "unavailable", provider: "x",
            mailboxAssignments: [], backup: "unknown", endpoint: "unknown", updateStatus: "unknown"
        ))
        XCTAssertTrue(placeholder.hasStatus)
    }

    @MainActor
    func testLastBackupDateComesOnlyFromAVerifiedBackup() async {
        let client = ScriptedOperationsClient()
        let model = SyncNodeSettingsViewModel(
            operationsController: SyncNodeOperationsController(client: client, authenticator: NoopLocalApprovalAuthenticator())
        )
        client.next = SyncNodeStatus(state: "uncertain", version: "1", reachability: "reachable", syncLag: "0s", storage: "s", providerIdentity: nil, assignments: [], backup: "uncertain", endpoint: "e", updateStatus: "blocked", completedAt: "2026-10-02T10:00:00Z")
        await model.runBackup()
        XCTAssertNil(model.lastVerifiedBackupAt, "an unverified backup has no date")

        client.next = SyncNodeStatus(state: "verified", version: "1", reachability: "reachable", syncLag: "0s", storage: "s", providerIdentity: nil, assignments: [], backup: "verified", endpoint: "e", updateStatus: "ready", completedAt: "2026-10-02T11:00:00Z")
        await model.runBackup()
        XCTAssertEqual(model.lastVerifiedBackupAt, "2026-10-02T11:00:00Z")

        client.next = SyncNodeStatus(state: "erased", version: "1", reachability: "reachable", syncLag: "0s", storage: "s", providerIdentity: nil, assignments: [], backup: "unchanged", endpoint: "e", updateStatus: "blocked", completedAt: "2026-10-02T12:00:00Z")
        await model.runErase(confirmation: model.eraseConfirmation)
        XCTAssertNil(model.lastVerifiedBackupAt, "an erase is not a backup")
    }

    func testSyncNodeStorageAndBackupHaveNoRawValues() {
        let storage = SyncNodeStatusText.storage("1500000000/10000000000 bytes")
        XCTAssertFalse(storage.contains("bytes"), storage)
        XCTAssertFalse(storage.contains("/"), storage)
        XCTAssertEqual(SyncNodeStatusText.storage("unavailable"), "Unknown")
        XCTAssertEqual(SyncNodeStatusText.storage("Unknown"), "Unknown")
        XCTAssertEqual(SyncNodeStatusText.backup("verified"), "Verified")
        XCTAssertEqual(SyncNodeStatusText.backup("uncertain"), "Not verified")
        XCTAssertEqual(SyncNodeStatusText.backup("unknown"), "Unknown")
        XCTAssertEqual(SyncNodeStatusText.backup("Unavailable"), "Unknown")
    }
}

#if os(macOS)
/// The Mac Plainpost Account page, Add Account in Sync Node mode and the Node account
/// page, hosted in a native window and read through accessibility.
@MainActor
final class PlainpostAccountSettingsPageTests: XCTestCase {
    func testLoadedPageShowsReadableDevicesActivityAndOneDeleteAction() async throws {
        let mac = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos, isCurrentDevice: true, status: "active",
            lastSecurityEventAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        )
        let phone = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("11111111-2222-4333-8444-555555555555"),
            platform: .ios, isCurrentDevice: false, status: "erasure_pending"
        )
        let event = try AccountSecurityEventV1(
            handle: Data(repeating: 0x11, count: 32), category: .deviceAdded,
            actorHandle: Data(repeating: 0x21, count: 32), targetHandle: nil, platform: .ios,
            status: "active", occurredAt: "2026-09-06T18:45:00Z"
        )
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: [mac, phone], events: [event]) },
            performAction: { _, _, _ in nil },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialSnapshot: .init(devices: [mac, phone], events: [event]),
            initialLoadState: .loaded
        )
        let session = AccountSessionViewModel(
            prepareSession: { _ in .active },
            centralServerOrigin: URL(string: "https://central.example"),
            securityFactory: { _ in model }
        )
        let host = AcceptanceHost(
            NavigationStack { PlainpostAccountSettingsPage(accountSessionModel: session) },
            size: NSSize(width: 820, height: 760)
        )
        defer { host.close() }
        let shows = await host.waitFor { elements in
            let texts = elements.flatMap(HostedAX.texts)
            // Each device row is one navigation button: name, then status · last activity.
            return texts.contains("Trusted Devices") && texts.contains { $0.hasPrefix("This Mac, Active · Last activity ") }
                && texts.contains("iPhone or iPad, Needs attention")
                && texts.contains("Security Activity") && texts.contains("Delete Plainpost Account…")
                && texts.contains("Your mail provider account and its mail aren't deleted.")
        }
        XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
        let texts = host.allTexts()
        for removed in ["Protected", "Account bound", "Danger Zone", "central.example", "Central server", "Sync Node", "erasure_pending", "Macos", "2026-"] {
            XCTAssertFalse(texts.contains { $0.contains(removed) }, "the page shows \(removed)\n" + host.axDump().joined(separator: "\n"))
        }

        try await host.press(label: "Security Activity")
        let activity = await host.waitFor { elements in
            let texts = elements.flatMap(HostedAX.texts)
            return texts.contains("New device added") && !texts.contains { $0.contains("device_added") || $0.contains("2026-09-06") }
        }
        XCTAssertTrue(activity, host.axDump().joined(separator: "\n"))
    }

    // Devices are navigation rows; the name field, Suspend and Revoke live on the device's
    // page, and Revoke confirms before the Apple sheet.
    func testDeviceRowOpensItsPageAndRevokeConfirmsBeforeApple() async throws {
        let mac = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos, isCurrentDevice: true, localLabel: "Work Mac", status: "active"
        )
        let phone = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("11111111-2222-4333-8444-555555555555"),
            platform: .ios, isCurrentDevice: false, status: "active"
        )
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: [mac, phone], events: []) },
            performAction: { _, _, _ in nil },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialSnapshot: .init(devices: [mac, phone], events: []),
            initialLoadState: .loaded
        )
        let session = AccountSessionViewModel(
            prepareSession: { _ in .active },
            centralServerOrigin: URL(string: "https://central.example"),
            securityFactory: { _ in model }
        )
        let host = AcceptanceHost(
            NavigationStack { PlainpostAccountSettingsPage(accountSessionModel: session) },
            size: NSSize(width: 820, height: 760)
        )
        defer { host.close() }
        let rows = await host.waitFor { elements in
            let texts = elements.flatMap(HostedAX.texts)
            return texts.contains("Work Mac, This Mac, Active") && texts.contains("iPhone or iPad, Active")
        }
        XCTAssertTrue(rows, host.axDump().joined(separator: "\n"))
        XCTAssertNil(host.element(identifier: "account-security.device-detail.name"), "the list has no inline name field")
        XCTAssertFalse(host.allTexts().contains { $0.hasPrefix("Revoke") }, "the list has no inline Revoke")

        try await host.press(identifier: "account-security.device.11111111-2222-4333-8444-555555555555")
        let page = await host.waitFor { elements in
            let texts = elements.flatMap(HostedAX.texts)
            return elements.contains { HostedAX.identifier($0) == "account-security.device-detail.name" }
                && texts.contains("Suspend…") && texts.contains("Revoke…")
                && texts.contains("Suspend blocks this device from your account. Revoke removes it permanently.")
        }
        XCTAssertTrue(page, host.axDump().joined(separator: "\n"))

        try await host.press(identifier: "account-security.device-detail.revoke")
        let confirmation = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains("Continue to Apple Confirmation")
        }
        XCTAssertTrue(confirmation, host.axDump().joined(separator: "\n"))
        XCTAssertFalse(model.hasPendingAppleAuthorization, "Apple waits for the confirmation")
        try await host.press(label: "Continue to Apple Confirmation")
        let sheet = await host.waitFor { elements in
            elements.contains { HostedAX.identifier($0) == "account-security.authorization.cancel" }
                && elements.flatMap(HostedAX.texts).contains("Revoke trusted device")
        }
        XCTAssertTrue(sheet, host.axDump().joined(separator: "\n"))
        XCTAssertTrue(model.hasPendingAppleAuthorization)
        try await host.press(identifier: "account-security.authorization.cancel")
        XCTAssertFalse(model.hasPendingAppleAuthorization)
    }

    /// The device page with a phone open, over a list the test can change.
    private func hostPhonePage(
        devices: AccountSecurityTestDevices,
        saveLabel: @escaping AccountSecurityViewModel.LabelSaver = { _, _ in }
    ) async throws -> (AcceptanceHost, AccountSecurityViewModel) {
        let initial = devices.current
        let model = AccountSecurityViewModel(
            loadSnapshot: { .init(devices: devices.current, events: []) },
            performAction: { _, _, _ in nil },
            saveLabel: saveLabel,
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialSnapshot: .init(devices: initial, events: []),
            initialLoadState: .loaded
        )
        let session = AccountSessionViewModel(
            prepareSession: { _ in .active },
            centralServerOrigin: URL(string: "https://central.example"),
            securityFactory: { _ in model }
        )
        let host = AcceptanceHost(
            NavigationStack { PlainpostAccountSettingsPage(accountSessionModel: session) },
            size: NSSize(width: 820, height: 760)
        )
        let rows = await host.waitFor { elements in
            elements.contains { HostedAX.identifier($0) == "account-security.device.\(AccountSecurityTestDevices.phoneID)" }
        }
        XCTAssertTrue(rows, host.axDump().joined(separator: "\n"))
        try await host.press(identifier: "account-security.device.\(AccountSecurityTestDevices.phoneID)")
        let page = await host.waitFor { elements in
            elements.contains { HostedAX.identifier($0) == "account-security.device-detail.name" }
        }
        XCTAssertTrue(page, host.axDump().joined(separator: "\n"))
        return (host, model)
    }

    // Revoke drops the device from the list; its open page says so and offers nothing more.
    func testADeviceRemovedWhileItsPageIsOpenSaysSo() async throws {
        let devices = try AccountSecurityTestDevices()
        let (host, model) = try await hostPhonePage(devices: devices)
        defer { host.close() }
        XCTAssertNotNil(host.element(identifier: "account-security.device-detail.revoke"))

        devices.current = [devices.mac]
        model.refresh()
        let removed = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains("This device was removed.")
                && !elements.contains { HostedAX.identifier($0) == "account-security.device-detail.revoke" }
                && !elements.contains { HostedAX.identifier($0) == "account-security.device-detail.suspend" }
        }
        XCTAssertTrue(removed, host.axDump().joined(separator: "\n"))
    }

    // The name saves when the page is left with Back, without Return.
    func testARenameSavesOnBack() async throws {
        let devices = try AccountSecurityTestDevices()
        let saved = AccountSecurityTestLabels()
        let (host, _) = try await hostPhonePage(devices: devices, saveLabel: { id, label in
            saved.labels.append("\(id.rawValue)=\(label)")
        })
        defer { host.close() }
        let element = try XCTUnwrap(host.element(identifier: "account-security.device-detail.name"))
        let field = try XCTUnwrap((element as? NSTextField) ?? ((element as? NSCell)?.controlView as? NSTextField), "name field: \(type(of: element))")
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Travel Phone", replacementRange: editor.selectedRange())
        await host.settle(10)
        XCTAssertEqual(saved.labels, [], "typing alone doesn't save")

        try await host.press(label: "Back")
        let didSave = await host.waitFor { _ in saved.labels == ["\(AccountSecurityTestDevices.phoneID)=Travel Phone"] }
        XCTAssertTrue(didSave, "saved: \(saved.labels)\n" + host.axDump().joined(separator: "\n"))
    }

    func testWithoutAnAccountThePageOffersConnect() async throws {
        var connects = 0
        var settingsHost = PlainpostSettingsHost()
        settingsHost.connectPlainpostAccount = { connects += 1 }
        let host = AcceptanceHost(
            PlainpostAccountSettingsPage(accountSessionModel: nil).plainpostSettingsHost(settingsHost),
            size: NSSize(width: 820, height: 500)
        )
        defer { host.close() }
        let shows = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains("Use your Plainpost account to add a Sync Node and manage trusted devices.")
        }
        XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
        try await host.press(label: "Connect Plainpost Account")
        XCTAssertEqual(connects, 1)
    }

    /// The device-wide runtime can move any Direct account to a Sync Node: every account page
    /// offers it, for that page's own account.
    func testUseSyncNodeIsOfferedOnEachAccountsPageForThatAccount() async throws {
        var attached: [AccountID] = []
        var settingsHost = PlainpostSettingsHost()
        settingsHost.useSyncNodeForAccount = { attached.append($0) }
        let page = AccountID("acc_preview")
        let host = AcceptanceHost(
            AccountSettingsPage(accountID: page, viewModel: .connectedPreview())
                .plainpostSettingsHost(settingsHost),
            size: NSSize(width: 820, height: 900)
        )
        defer { host.close() }
        let loaded = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains { $0.hasPrefix("Keep on this device") }
        }
        XCTAssertTrue(loaded, host.axDump().joined(separator: "\n"))
        try await host.press(label: "Use Sync Node for This Account")
        XCTAssertEqual(attached, [page])
    }

    func testAddAccountGmailConnectsGoogleToTheSyncNodeInNodeMode() async throws {
        var connects = 0
        let nodeSettings = SyncNodeSettingsViewModel(connectProvider: { connects += 1 })
        let accountSetup = AccountSetupViewModel.connectedPreview()
        let page = AddAccountSettingsPage(accountSetup: accountSetup, nodeSettings: nodeSettings, selection: nil)
        let host = AcceptanceHost(page, size: NSSize(width: 900, height: 800))
        defer { host.close() }
        let shows = await host.waitFor { elements in elements.contains { HostedAX.identifier($0) == "account-setup.provider.gmail" } }
        XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
        try await host.press(identifier: "account-setup.provider.gmail")
        XCTAssertEqual(connects, 1)
        XCTAssertFalse(host.allTexts().contains("Sign in with Google"), "the direct Google flow must not open")
    }

    // Mac has no provider re-sign-in for Node accounts, so the page explains instead of
    // offering a dead-end button.
    func testMacNodeAccountNeedingSignInExplainsWithoutADeadEndButton() async throws {
        let account = NodeMailAccount(
            logicalMailboxID: LogicalMailboxID(rawValue: Data(repeating: 0x41, count: 32))!,
            providerIdentity: "ada@example.com", providerKind: "generic", isPrimary: true,
            state: .authenticationRequired, mailboxes: []
        )
        let host = AcceptanceHost(NodeAccountSettingsPage(account: account), size: NSSize(width: 700, height: 400))
        defer { host.close() }
        let shows = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains("Your Sync Node can't sign in to this account, so it isn't syncing.")
        }
        XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
        XCTAssertFalse(host.allTexts().contains { $0.hasPrefix("Reconnect…") })
    }
}
#endif

private final class ScriptedOperationsClient: SyncNodeOperationsClient, @unchecked Sendable {
    var next: SyncNodeStatus?
    func status() async throws -> SyncNodeStatus { try XCTUnwrap(next) }
    func backup() async throws -> SyncNodeStatus { try XCTUnwrap(next) }
    func erase() async throws -> SyncNodeStatus { try XCTUnwrap(next) }
}

#if os(macOS)
/// A trusted-device list a hosted test can change between loads.
@MainActor
final class AccountSecurityTestDevices {
    static let phoneID = "11111111-2222-4333-8444-555555555555"
    let mac: AccountLifecycleDeviceSummary
    let phone: AccountLifecycleDeviceSummary
    var current: [AccountLifecycleDeviceSummary]

    init() throws {
        mac = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos, isCurrentDevice: true, localLabel: "Work Mac", status: "active"
        )
        phone = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID(Self.phoneID),
            platform: .ios, isCurrentDevice: false, status: "active"
        )
        current = [mac, phone]
    }
}

@MainActor
final class AccountSecurityTestLabels {
    var labels: [String] = []
}
#endif
