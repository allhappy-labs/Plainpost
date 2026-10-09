import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostUI

#if os(macOS)
    import AppKit
    import SwiftUI

    /// The macOS Settings "Sync Node" page hosted in a native window with an
    /// injected account session. Assertions read the hosted accessibility tree
    /// and interactions go through accessibility presses.
    @MainActor
    final class SyncNodeSettingsPageTests: XCTestCase {
        private static let importIdentifier = "settings.sync-node.import"
        private static let enrollmentIdentifier = "settings.sync-node.enrollment"
        /// A Status-section row label, shown only once the Sync Node is enrolled.
        private static let statusRow = "Storage"

        func testMacSettingsListSyncNodeRightAfterPlainpostAccount() {
            let sections = PlainpostSettingsSection.allCases
            XCTAssertEqual(sections.firstIndex(of: .syncNode), sections.firstIndex(of: .plainpostAccount).map { $0 + 1 })
            XCTAssertEqual(PlainpostSettingsSection.syncNode.title, "Sync Node")
            XCTAssertEqual(PlainpostSettingsSection.syncNode.systemImage, "server.rack")
        }

        func testSignInImportGateIsUnchangedAndSettingsImportRequiresSignedInAccount() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeBootstrapImportModel: importModel
            )

            XCTAssertTrue(session.showsSyncNodeBootstrapImport)
            XCTAssertNil(session.syncNodeSettingsImportModel)
            let signIn = AcceptanceHost(
                AccountSessionRootView(model: session) { _, _ in Text("Authorized mailbox") },
                size: NSSize(width: 720, height: 640)
            )
            let signInShowsImport = await signIn.waitFor { elements in
                elements.contains { HostedAX.texts($0).contains("Import Server Setup") }
            }
            XCTAssertTrue(signInShowsImport, signIn.axDump().joined(separator: "\n"))

            await activate(session)

            XCTAssertFalse(session.showsSyncNodeBootstrapImport)
            XCTAssertTrue(session.syncNodeSettingsImportModel === importModel)
            let signInHidesImport = await signIn.waitFor { elements in
                elements.contains { HostedAX.texts($0).contains("Authorized mailbox") }
                    && !elements.contains { HostedAX.texts($0).contains("Import Server Setup") }
            }
            XCTAssertTrue(signInHidesImport, signIn.axDump().joined(separator: "\n"))
            signIn.close()
        }

        func testWithoutImportedProfilePageShowsServerSetupImportThenConnectAfterImport() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            let connect = fixture.connectModel()
            // Production throws `.noSyncNode` when neither a profile nor an enrolled node exists.
            let factory = SettingsEnrollmentFactory(results: [nil, connect])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)

            let host = hostSettings(session)
            defer { host.close() }
            let showsImport = await host.waitFor { elements in
                factory.calls == 1
                    && session.syncNodeEnrollmentLoadPresentation != .loading
                    && elements.contains { HostedAX.identifier($0) == Self.importIdentifier }
                    && elements.contains { HostedAX.texts($0).contains("Import Server Setup…") }
                    && host.texts(identifier: "sync-node.settings.status").contains("No Sync Node")
            }
            XCTAssertTrue(showsImport, "factory calls: \(factory.calls)\n" + host.axDump().joined(separator: "\n"))
            XCTAssertNotNil(host.element(identifier: "sync-node.overview"))
            XCTAssertNil(host.element(identifier: Self.enrollmentIdentifier))
            XCTAssertFalse(host.allTexts().contains(Self.statusRow))
            XCTAssertFalse(
                host.allTexts().contains("Try Again"),
                "An account with no Sync Node goes straight to the import step."
            )

            importModel.fileAccess = SyncNodeBootstrapFileAccess(
                startAccessing: { _ in true },
                stopAccessing: { _ in },
                read: { [document = try fixture.profileDocument()] _, _ in document }
            )
            session.handleSyncNodeBootstrapFileImporter(
                .success([URL(fileURLWithPath: "/protected/node.plainpostserver")])
            )

            let serverHost = try XCTUnwrap(fixture.profile.canonicalOrigin.url.host())
            let showsConnect = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == Self.enrollmentIdentifier }
                    && elements.contains { HostedAX.texts($0).contains(serverHost) }
                    && host.texts(identifier: "sync-node.settings.status").contains("Ready to connect")
            }
            XCTAssertTrue(showsConnect, host.axDump().joined(separator: "\n"))
            XCTAssertTrue(session.syncNodeEnrollmentModel === connect)
            XCTAssertEqual(factory.calls, 2)
        }

        func testImportedProfileShowsPinnedTargetAndConnectStep() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let connect = fixture.connectModel()
            let factory = SettingsEnrollmentFactory(results: [connect])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)

            let host = hostSettings(session, nodeSettings: SyncNodeSettingsViewModel())
            defer { host.close() }
            let serverHost = try XCTUnwrap(fixture.profile.canonicalOrigin.url.host())
            let showsConnect = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == Self.enrollmentIdentifier }
                    && elements.contains { HostedAX.identifier($0) == "sync-node-verify-fingerprint" }
                    && elements.contains { HostedAX.texts($0).contains(serverHost) }
                    && elements.contains { HostedAX.identifier($0) == "sync-node-connect" }
                    && host.texts(identifier: "sync-node.settings.status").contains("Ready to connect")
            }
            XCTAssertTrue(showsConnect, host.axDump().joined(separator: "\n"))
            XCTAssertFalse(host.allTexts().contains("Connected"), "a Node that isn't enrolled is never shown as connected")
            XCTAssertTrue(connect.canBeginConnect, "The Connect step starts from the provisioned target.")
            XCTAssertFalse(
                host.allTexts().contains(Self.statusRow),
                "Node status is shown only after the Sync Node is enrolled."
            )
        }

        func testEnrolledSyncNodeShowsStatusThenConnectionWithoutDiagnostics() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let factory = SettingsEnrollmentFactory(results: [fixture.connectedReplaceableModel()])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let nodeSettings = SyncNodeSettingsViewModel(
                snapshot: SyncNodeSettingsSnapshot(
                    version: "node-9.4.1", reachability: "reachable", syncLag: "2s",
                    storage: "1500000000/10000000000 bytes", provider: "gmail-identity", mailboxAssignments: ["Inbox"],
                    backup: "verified", endpoint: "https://node.example", updateStatus: "Current"
                )
            )

            let host = hostSettings(session, nodeSettings: nodeSettings)
            defer { host.close() }
            let serverHost = try XCTUnwrap(fixture.profile.canonicalOrigin.url.host())
            let showsNode = await host.waitFor { elements in
                let texts = elements.flatMap(HostedAX.texts)
                return texts.contains(Self.statusRow)
                    && host.texts(identifier: "sync-node.settings.status").contains("Connected")
                    && texts.contains("Server") && texts.contains(serverHost)
                    && elements.contains { HostedAX.identifier($0) == "sync-node.settings.verify-fingerprint" }
                    && elements.contains { HostedAX.identifier($0) == "sync-node.settings.replace-server-setup" }
            }
            XCTAssertTrue(showsNode, host.axDump().joined(separator: "\n"))
            let texts = host.allTexts()
            let overview = try XCTUnwrap(texts.firstIndex(of: "Connected"))
            let details = try XCTUnwrap(texts.firstIndex(of: Self.statusRow))
            let server = try XCTUnwrap(texts.firstIndex(of: "Server"))
            XCTAssertLessThan(overview, details, "the overview comes before the Node's details")
            XCTAssertLessThan(details, server, "the details come before the Server section")
            XCTAssertNil(host.element(identifier: "sync-node-enrollment-connected"), "the overview is the only connection status")
            XCTAssertEqual(texts.filter { $0 == "Connected" }.count, 1, host.axDump().joined(separator: "\n"))
            for removed in ["node-9.4.1", "Private Node health and mailbox assignments.", "gmail-identity", "https://node.example", "Current Sync Node", "bytes", fixture.profile.nodeDeviceID.rawValue, fixture.profile.canonicalOrigin.url.absoluteString] {
                XCTAssertFalse(texts.contains { $0.contains(removed) }, "the page shows \(removed)\n" + host.axDump().joined(separator: "\n"))
            }
        }

        // Signed out, the page still shows its overview rather than an empty form.
        func testSignedOutPageShowsTheOverview() async throws {
            let session = AccountSessionViewModel(prepareSession: { _ in .signInRequired })
            session.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
            let host = hostSettings(session)
            defer { host.close() }
            let showsOverview = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node.overview" }
                    && host.texts(identifier: "sync-node.settings.status").contains("Sign in to Plainpost")
            }
            XCTAssertTrue(showsOverview, host.axDump().joined(separator: "\n"))
            XCTAssertNil(host.element(identifier: "sync-node.overview.connect-account"), "the Mac host offers no sign-in action here")
        }

        // An account that exists but can't be used points to Plainpost Account, not sign-in.
        func testUnusableAccountPageSaysUnavailableInsteadOfSignIn() async throws {
            let session = AccountSessionViewModel(prepareSession: { _ in .suspended })
            session.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
            let host = hostSettings(session)
            defer { host.close() }
            let shows = await host.waitFor { _ in
                host.texts(identifier: "sync-node.settings.status").contains("Plainpost account unavailable")
            }
            XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
            XCTAssertTrue(host.allTexts().contains("Open Plainpost Account in Settings to see why."))
            XCTAssertFalse(host.allTexts().contains("Sign in to Plainpost"))
        }

        private static func reachableNodeSettings() -> SyncNodeSettingsViewModel {
            SyncNodeSettingsViewModel(snapshot: SyncNodeSettingsSnapshot(
                version: "node", reachability: "reachable", syncLag: "2s",
                storage: "1500000000/10000000000 bytes", provider: "gmail-identity", mailboxAssignments: ["Inbox"],
                backup: "verified", endpoint: "https://node.example", updateStatus: "Current"
            ))
        }

        // The Server Setup was retired after install and the enrollment load fails: the Node
        // still reports a status, so it is enrolled, never "No Sync Node" with setup steps.
        func testEnrolledNodeWhoseLoadFailedIsNeverShownAsNotSetUp() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let factory = SettingsEnrollmentFactory(results: [nil], failure: AccountRuntimeError.untrustedResponse)
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            )
            await activate(session)
            let host = hostSettings(session, nodeSettings: Self.reachableNodeSettings())
            defer { host.close() }
            let shows = await host.waitFor { elements in
                host.texts(identifier: "sync-node.settings.status").contains("Sync Node unavailable")
                    && elements.contains { HostedAX.identifier($0) == "sync-node.overview.try-again" }
                    && elements.flatMap(HostedAX.texts).contains(Self.statusRow)
            }
            XCTAssertTrue(shows, "factory calls: \(factory.calls)\n" + host.axDump().joined(separator: "\n"))
            XCTAssertFalse(host.allTexts().contains("No Sync Node"))
            XCTAssertNil(host.element(identifier: Self.importIdentifier), "no setup steps for an enrolled Node")
            XCTAssertNil(host.element(identifier: "settings.sync-node.connect-step"))
        }

        // A real load failure (here, no Server Setup and an unreadable trust state) leaves it
        // unknown whether the account has a Node: never "No Sync Node" with setup steps, but
        // "Sync Node unavailable" and Try Again, which loads again.
        func testFailedLoadWithoutImportedProfileOffersTryAgainNotSetup() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let factory = SettingsEnrollmentFactory(results: [nil], failure: AccountRuntimeError.secretUnavailable)
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            let shows = await host.waitFor { elements in
                host.texts(identifier: "sync-node.settings.status").contains("Sync Node unavailable")
                    && elements.contains { HostedAX.identifier($0) == "sync-node.overview.try-again" }
            }
            XCTAssertTrue(shows, "factory calls: \(factory.calls)\n" + host.axDump().joined(separator: "\n"))
            XCTAssertEqual(
                session.syncNodeEnrollmentLoadPresentation,
                .failed(message: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation.failureMessage)
            )
            XCTAssertFalse(host.allTexts().contains("No Sync Node"))
            XCTAssertFalse(host.allTexts().contains("Import Server Setup…"))
            XCTAssertNil(host.element(identifier: Self.importIdentifier), "no setup steps while the Node is unknown")
            XCTAssertNil(host.element(identifier: "settings.sync-node.connect-step"))

            let callsBeforeRetry = factory.calls
            session.retrySyncNodeEnrollment()
            for _ in 0 ..< 200 where factory.calls == callsBeforeRetry { await Task.yield() }
            XCTAssertEqual(factory.calls, callsBeforeRetry + 1)
        }

        // An offline lease loads no enrollment model, but the Node's status still shows.
        func testOfflineLeaseShowsTheEnrolledNodeNotTheSetupSteps() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let session = AccountSessionViewModel(
                prepareSession: { _ in .offlineLease(expiresAt: Date(timeIntervalSince1970: 2_000_000_000)) },
                syncNodeEnrollmentFactory: { throw AccountRuntimeError.secretUnavailable },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            )
            session.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
            for _ in 0 ..< 200 where session.presentation.offlineLeaseExpiry == nil { await Task.yield() }
            XCTAssertNotNil(session.presentation.offlineLeaseExpiry)
            let host = hostSettings(session, nodeSettings: Self.reachableNodeSettings())
            defer { host.close() }
            let shows = await host.waitFor { elements in
                host.texts(identifier: "sync-node.settings.status").contains("Connected")
                    && elements.flatMap(HostedAX.texts).contains(Self.statusRow)
            }
            XCTAssertTrue(shows, host.axDump().joined(separator: "\n"))
            XCTAssertEqual(session.syncNodeEnrollmentLoadPresentation, .idle)
            XCTAssertFalse(host.allTexts().contains("No Sync Node"))
            XCTAssertNil(host.element(identifier: Self.importIdentifier), "no setup steps for an enrolled Node")
        }

        // Step 1 shows the server Connect would use; a failed re-import is its own row and
        // doesn't hide that server or Verify Fingerprint.
        func testFailedReimportKeepsTheTargetServerAndFingerprint() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let connect = fixture.connectModel()
            let factory = SettingsEnrollmentFactory(results: [connect])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            let serverHost = try XCTUnwrap(fixture.profile.canonicalOrigin.url.host())
            let ready = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-verify-fingerprint" }
                    && elements.contains { HostedAX.texts($0).contains(serverHost) }
            }
            XCTAssertTrue(ready, host.axDump().joined(separator: "\n"))

            XCTAssertFalse(session.importSyncNodeBootstrapProfile(from: URL(fileURLWithPath: "/protected/notes.txt")))
            XCTAssertEqual(importModel.presentation, .failure(message: SyncNodeBootstrapImportViewModel.failureMessage))
            let keeps = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node.settings.import-failure" }
                    && elements.contains { HostedAX.identifier($0) == "sync-node-verify-fingerprint" }
                    && elements.contains { HostedAX.identifier($0) == "sync-node.settings.imported-server" }
                    && elements.contains { HostedAX.texts($0).contains(serverHost) }
                    && elements.contains { HostedAX.identifier($0) == "sync-node.settings.use-different-file" }
            }
            XCTAssertTrue(keeps, host.axDump().joined(separator: "\n"))
            XCTAssertTrue(session.syncNodeEnrollmentModel === connect)
            XCTAssertNil(host.element(identifier: "sync-node.settings.import-server-setup"))
        }

        // An enrolled Node whose status isn't reachable is reported once, as unreachable,
        // and nothing else on the page says it is connected.
        func testUnreachableEnrolledNodeIsNeverShownAsConnected() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let factory = SettingsEnrollmentFactory(results: [fixture.enrolledModel()])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            )
            await activate(session)
            let refreshes = RefreshCounter()
            let nodeSettings = SyncNodeSettingsViewModel(
                snapshot: SyncNodeSettingsSnapshot(
                    version: "node", reachability: "Unavailable", syncLag: "Unknown",
                    storage: "Unknown", provider: "Unknown", mailboxAssignments: [],
                    backup: "unknown", endpoint: "Unknown", updateStatus: "Unknown"
                ),
                refresh: {
                    refreshes.increment()
                    return SyncNodeSettingsSnapshot(
                        version: "node", reachability: "Unavailable", syncLag: "Unknown",
                        storage: "Unknown", provider: "Unknown", mailboxAssignments: [],
                        backup: "unknown", endpoint: "Unknown", updateStatus: "Unknown"
                    )
                }
            )
            let host = hostSettings(session, nodeSettings: nodeSettings)
            defer { host.close() }
            let showsUnreachable = await host.waitFor { elements in
                host.texts(identifier: "sync-node.settings.status").contains("Can’t reach your Sync Node")
                    && elements.contains { HostedAX.identifier($0) == "sync-node.overview.check-again" }
            }
            XCTAssertTrue(showsUnreachable, host.axDump().joined(separator: "\n"))
            XCTAssertFalse(host.allTexts().contains { $0 == "Connected" || $0 == "Needs attention" }, host.axDump().joined(separator: "\n"))
            let before = refreshes.count
            try await host.press(identifier: "sync-node.overview.check-again")
            let refreshed = await host.waitFor { _ in refreshes.count > before }
            XCTAssertTrue(refreshed)
        }

        func testConnectingSyncNodePreparesCalendarAuthorityWithoutRelaunch() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: false))
            let enrolled = fixture.enrolledModel(initialConnectionPresentation: .connectionFailed)
            let factory = SettingsEnrollmentFactory(results: [enrolled])
            let calendar = CalendarAuthorityRequests()
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel,
                calendarAuthorityFactory: {
                    calendar.count += 1
                    throw AccountRuntimeError.secretUnavailable
                }
            )
            await activate(session)

            let host = hostSettings(session)
            defer { host.close() }
            let showsRetry = await host.waitFor { elements in
                elements.contains { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains("Retry Connection") }
            }
            XCTAssertTrue(showsRetry, host.axDump().joined(separator: "\n"))
            XCTAssertEqual(calendar.count, 0)

            try await host.press(label: "Retry Connection")

            let connected = await host.waitFor { _ in
                enrolled.connectionPresentation == .connected && calendar.count == 1
            }
            XCTAssertTrue(connected, "calendar requests: \(calendar.count)\n" + host.axDump().joined(separator: "\n"))
        }

        func testCommittedAdmissionShowsRetryVerificationAndKeepOpenGuidanceOnly() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let failed = try await fixture.verificationFailedModel()
            let factory = SettingsEnrollmentFactory(results: [failed])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)

            let host = hostSettings(session)
            defer { host.close() }
            let showsRetryVerification = await host.waitFor { elements in
                let texts = elements.flatMap(HostedAX.texts)
                return elements.contains { HostedAX.identifier($0) == "sync-node-retry-verification" }
                    && texts.contains(SyncNodeEnrollmentViewModel.verificationFailureMessage)
                    && texts.contains(SyncNodeEnrollmentViewModel.keepOpenMessage)
            }
            XCTAssertTrue(showsRetryVerification, host.axDump().joined(separator: "\n"))
            XCTAssertFalse(host.allTexts().contains("Retry"), "A committed admission must not offer a fresh start.")
            XCTAssertNil(host.element(identifier: "sync-node-connect"))

            try await host.press(label: "Retry Verification")

            let connected = await host.waitFor { _ in failed.connectionPresentation == .connected }
            XCTAssertTrue(connected, host.axDump().joined(separator: "\n"))
        }

        func testOutdatedServerSetupShowsFixedCopyWithoutConnectOrRetry() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let outdated = try fixture.outdatedProfileModel()
            let factory = SettingsEnrollmentFactory(results: [outdated])
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { try factory.make() },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)

            let host = hostSettings(session)
            defer { host.close() }
            let showsOutdated = await host.waitFor { elements in
                elements.flatMap(HostedAX.texts).contains(SyncNodeEnrollmentViewModel.outdatedProfileMessage)
            }
            XCTAssertTrue(showsOutdated, host.axDump().joined(separator: "\n"))
            XCTAssertTrue(host.allTexts().contains(SyncNodeOverview.differentFileHint), host.axDump().joined(separator: "\n"))
            XCTAssertTrue(host.allTexts().contains("Use a Different File…"), "the hint names the import button on this page")
            XCTAssertNil(host.element(identifier: "sync-node-connect"))
            XCTAssertFalse(host.allTexts().contains("Retry"))
        }

        // An uncertain commit Central never answered 2xx offers Stop and Start
        // Over on both surfaces. It returns to Connect only after a proven
        // cancel, and a refused cancel keeps Retry Installation.
        func testUncertainCommitStopAndStartOver() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let refused = try await fixture.uncertainCommitModel(cancelFails: true)
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { refused },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            let showsStop = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-stop-and-start-over" }
                    && elements.flatMap(HostedAX.texts).contains { $0.contains(SyncNodeEnrollmentViewModel.stopAndStartOverGuidance) }
            }
            XCTAssertTrue(showsStop, host.axDump().joined(separator: "\n"))
            try await host.press(identifier: "sync-node-stop-and-start-over")
            let showsUnconfirmed = await host.waitFor { elements in
                elements.flatMap(HostedAX.texts).contains(SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage)
                    && elements.contains { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains("Retry Installation") }
            }
            XCTAssertTrue(showsUnconfirmed, host.axDump().joined(separator: "\n"))
            XCTAssertFalse(host.allTexts().contains { $0.contains(SyncNodeEnrollmentViewModel.stopAndStartOverGuidance) }, host.axDump().joined(separator: "\n"))
            XCTAssertEqual(refused.state, .commitResponseUncertain)
            XCTAssertTrue(refused.retainsInstallationReplay)

            // A proven cancel returns to Connect, which waits for the cancelled claim to expire.
            let accepted = try await fixture.uncertainCommitModel()
            let acceptedHost = try await hostPage(enrollment: accepted)
            defer { acceptedHost.close() }
            let acceptedShowsStop = await acceptedHost.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-stop-and-start-over" }
                    && elements.flatMap(HostedAX.texts).contains { $0.contains(SyncNodeEnrollmentViewModel.stopAndStartOverGuidance) }
            }
            XCTAssertTrue(acceptedShowsStop, acceptedHost.axDump().joined(separator: "\n"))
            try await acceptedHost.press(identifier: "sync-node-stop-and-start-over")
            let showsReady = await acceptedHost.waitFor { elements in
                elements.flatMap(HostedAX.texts).contains { $0.hasPrefix("You can connect again in about ") }
                    && elements.contains { HostedAX.identifier($0) == "sync-node-connect" && !HostedAX.enabled($0) }
            }
            XCTAssertTrue(showsReady, acceptedHost.axDump().joined(separator: "\n"))
            XCTAssertEqual(accepted.state, .enterCode)
            XCTAssertFalse(accepted.canBeginConnect)
            XCTAssertNil(acceptedHost.element(identifier: "sync-node-stop-and-start-over"))
        }

        // After sign-out a retained admission stays in memory, but neither
        // surface shows the prior account's server, Node fingerprint or Retry
        // actions. Signing back in as its owner shows them again.
        func testRetainedAdmissionIsHiddenAfterSignOut() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let retained = try await fixture.uncertainCommitModel(owned: true)
            let origin = try XCTUnwrap(retained.targetOrigin.flatMap { URL(string: $0)?.host() })
            let reader = SettingsOwnerReaderScript(fixture.owner)
            let state = SessionStateScript(.active)
            let session = AccountSessionViewModel(
                prepareSession: { _ in state.state },
                syncNodeEnrollmentFactory: { retained },
                syncNodeEnrollmentOwnerReader: { reader.read() },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            for surface in [host] {
                let showsRetained = await surface.waitFor { elements in
                    let texts = elements.flatMap(HostedAX.texts)
                    return elements.contains { HostedAX.identifier($0) == "sync-node-retry-installation" }
                        && texts.contains { $0.contains(origin) }
                        && elements.contains { HostedAX.identifier($0) == "sync-node-verify-fingerprint" }
                }
                XCTAssertTrue(showsRetained, surface.axDump().joined(separator: "\n"))
            }
            // Re-rendering both surfaces never reads the owner.
            let readsBeforeRendering = reader.reads
            for _ in 0 ..< 5 {
                session.objectWillChange.send()
                await host.settle(2)
                _ = host.axDump()
            }
            XCTAssertEqual(reader.reads, readsBeforeRendering, "a view body read the owner")

            reader.owner = nil
            state.state = .signInRequired
            session.prepare()
            for surface in [host] {
                let hidden = await surface.waitFor { elements in
                    let texts = elements.flatMap(HostedAX.texts)
                    return texts.contains { $0.contains(AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage) }
                        && !texts.contains { $0.contains(origin) }
                        && !elements.contains { ["sync-node-retry-installation", "sync-node-stop-and-start-over", "sync-node-retry-verification", "sync-node-retry-activation", "sync-node-verify-fingerprint"].contains(HostedAX.identifier($0) ?? "") }
                }
                XCTAssertTrue(hidden, surface.axDump().joined(separator: "\n"))
            }
            XCTAssertTrue(session.syncNodeEnrollmentModel === retained)
            XCTAssertEqual(retained.state, .commitResponseUncertain)

            reader.owner = fixture.owner
            state.state = .active
            session.prepare()
            for surface in [host] {
                let shownAgain = await surface.waitFor { elements in
                    elements.contains { HostedAX.identifier($0) == "sync-node-retry-installation" }
                        && !elements.flatMap(HostedAX.texts).contains { $0.contains(AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage) }
                }
                XCTAssertTrue(shownAgain, surface.axDump().joined(separator: "\n"))
            }
        }

        // A one-off Keychain error while reading the owner hides the owner's
        // own retained connection. Opening either Sync Node surface reads the
        // owner again, so Retry Installation returns without another prepare.
        func testOpeningThePageRecoversFromATransientOwnerReadError() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let retained = try await fixture.uncertainCommitModel(owned: true)
            let reader = SettingsOwnerReaderScript(fixture.owner)
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { retained },
                syncNodeEnrollmentOwnerReader: { try reader.readOrThrow() },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            )
            await activate(session)
            session.prepareSyncNodeEnrollment()
            for _ in 0 ..< 200 where session.presentableSyncNodeEnrollmentModel !== retained { await Task.yield() }
            XCTAssertTrue(session.presentableSyncNodeEnrollmentModel === retained)

            func failOneOwnerRead() async {
                reader.fails = true
                let readsBefore = reader.reads
                session.prepare()
                for _ in 0 ..< 200 where reader.reads == readsBefore || session.presentableSyncNodeEnrollmentModel != nil { await Task.yield() }
                reader.fails = false
                XCTAssertTrue(session.syncNodeEnrollmentModel === retained)
                XCTAssertNil(session.presentableSyncNodeEnrollmentModel, "the cached verdict is still the failed read")
            }

            await failOneOwnerRead()
            let host = hostSettings(session)
            let pageShowsRetry = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-retry-installation" }
            }
            XCTAssertTrue(pageShowsRetry, host.axDump().joined(separator: "\n"))
            host.close()
            XCTAssertEqual(retained.state, .commitResponseUncertain)
        }

        // Recovery offers Replace Sync Node; a confirmed replacement continues with Apple.
        func testRecoveryRequiredOffersReplaceThenConnect() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let recovery = fixture.recoveryModel()
            let host = try await hostPage(enrollment: recovery)
            defer { host.close() }
            let showsReplace = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-replace" }
                    && elements.flatMap(HostedAX.texts).contains { $0.contains("this device isn’t connected to it") }
            }
            XCTAssertTrue(showsReplace, host.axDump().joined(separator: "\n"))
            try await pressReplaceThroughDialog(host)
            let ready = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-connect" && HostedAX.enabled($0) }
            }
            XCTAssertTrue(ready, "ready: \(recovery.isReplacementReady) connect: \(recovery.canBeginConnect)\n" + host.axDump().joined(separator: "\n"))
            XCTAssertTrue(recovery.canBeginConnect)
        }

        // Replace goes through the real confirmation dialog on both surfaces
        // and must leave Continue with Apple enabled, not loop back to Replace.
        func testConfirmedReplaceThroughDialogReachesConnect() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let connected = fixture.connectedReplaceableModel()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { connected },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            try await pressReplaceThroughDialog(host)
            let pageReady = await host.waitFor { elements in
                connected.isReplacementReady && connected.canBeginConnect
                    && elements.contains { HostedAX.identifier($0) == "sync-node-connect" && HostedAX.enabled($0) }
            }
            XCTAssertTrue(pageReady, "ready: \(connected.isReplacementReady) connect: \(connected.canBeginConnect)\n" + host.axDump().joined(separator: "\n"))
        }

        // Dismissing the Replace dialog without confirming clears consent and
        // leaves the Node presented as before, on both surfaces. On the Sync
        // Node page a confirmed Replace can also be withdrawn the same way.
        func testDismissingReplaceDialogClearsConsentAndRestoresPresentation() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let connected = fixture.connectedReplaceableModel()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { connected },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            try await dismissReplaceDialog(host)
            let pageRestored = await host.waitFor { elements in
                host.texts(identifier: "sync-node.settings.status").contains("Connected")
                    && !elements.contains { HostedAX.identifier($0) == "sync-node-connect" }
            }
            XCTAssertTrue(pageRestored, host.axDump().joined(separator: "\n"))
            XCTAssertFalse(connected.isReplacementConfirmationVisible)
            XCTAssertNil(connected.selectedReplacementNodeID)
            XCTAssertFalse(connected.isReplacementReady)
            XCTAssertEqual(connected.connectionPresentation, .connected)

            try await pressReplaceThroughDialog(host)
            let confirmed = await host.waitFor { _ in connected.isReplacementReady && connected.connectionPresentation == .ready }
            XCTAssertTrue(confirmed, host.axDump().joined(separator: "\n"))
            try await dismissReplaceDialog(host)
            let withdrawn = await host.waitFor { elements in
                connected.connectionPresentation == .connected
                    && host.texts(identifier: "sync-node.settings.status").contains("Connected")
                    && !elements.contains { HostedAX.identifier($0) == "sync-node-connect" }
            }
            XCTAssertTrue(withdrawn, "presentation: \(connected.connectionPresentation)\n" + host.axDump().joined(separator: "\n"))
            XCTAssertFalse(connected.isReplacementReady)
            XCTAssertNil(connected.selectedReplacementNodeID)
        }

        // Pre-commit failures are pressable: a server mismatch starts over to
        // Continue with Apple on both surfaces.
        func testServerMismatchStartsOver() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let pageModel = try await fixture.serverMismatchModel()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { pageModel },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            let pageShowsStartOver = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-start-over" && HostedAX.texts($0).contains("Start Over") }
                    && elements.flatMap(HostedAX.texts).contains(SyncNodeOverview.differentFileHint)
            }
            XCTAssertTrue(pageShowsStartOver, host.axDump().joined(separator: "\n"))
            XCTAssertNil(host.element(identifier: "sync-node-retry"))
            try await host.press(identifier: "sync-node-start-over")
            // The rejection cancelled the claim the Node still presents.
            let pageConnect = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-connect" && !HostedAX.enabled($0) }
                    && elements.flatMap(HostedAX.texts).contains { $0.hasPrefix("You can connect again in about ") }
            }
            XCTAssertTrue(pageConnect, host.axDump().joined(separator: "\n"))
        }

        func testRetryInstallationAndRetryActivationArePressable() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let uncertain = try await fixture.uncertainCommitModel()
            let importModel = SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { uncertain },
                syncNodeBootstrapImportModel: importModel
            )
            await activate(session)
            let host = hostSettings(session)
            defer { host.close() }
            let showsRetryInstallation = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-retry-installation" }
            }
            XCTAssertTrue(showsRetryInstallation, host.axDump().joined(separator: "\n"))
            try await host.press(identifier: "sync-node-retry-installation")
            let installed = await host.waitFor { _ in uncertain.connectionPresentation == .connected }
            XCTAssertTrue(installed, host.axDump().joined(separator: "\n"))

            let activation = try await fixture.activationUncertainModel()
            let activationHost = try await hostPage(enrollment: activation)
            defer { activationHost.close() }
            let showsRetryActivation = await activationHost.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-retry-activation" }
                    && elements.flatMap(HostedAX.texts).contains { $0.contains(SyncNodeEnrollmentViewModel.activationResumesGuidance) }
            }
            XCTAssertTrue(showsRetryActivation, activationHost.axDump().joined(separator: "\n"))
            try await activationHost.press(identifier: "sync-node-retry-activation")
            let activated = await activationHost.waitFor { _ in activation.connectionPresentation == .connected }
            XCTAssertTrue(activated, activationHost.axDump().joined(separator: "\n"))
        }

        // The page explains an outdated Server Setup even when the Node needs recovery or
        // is unreachable, and offers no Replace Sync Node.
        func testOutdatedServerSetupIsExplainedInRecoveryStates() async throws {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            for presentation in [SyncNodeEnrollmentViewModel.ConnectionPresentation.recoveryRequired, .connectionFailed] {
                let model = try fixture.outdatedRecoveryModel(presentation: presentation)
                let host = try await hostPage(enrollment: model)
                defer { host.close() }
                let explains = await host.waitFor { elements in
                    let texts = elements.flatMap(HostedAX.texts)
                    return texts.contains(SyncNodeEnrollmentViewModel.outdatedProfileMessage)
                        && texts.contains(SyncNodeEnrollmentViewModel.serverSetupImportHint)
                        && elements.contains { HostedAX.identifier($0) == "sync-node.settings.replace-server-setup" }
                }
                XCTAssertTrue(explains, "\(presentation)\n" + host.axDump().joined(separator: "\n"))
                XCTAssertNil(host.element(identifier: "sync-node-replace"))
            }
        }

        private func pressReplaceThroughDialog(_ host: AcceptanceHost) async throws {
            try await openReplaceDialog(host)
            try await host.press(label: "Replace Sync Node", in: host.window.attachedSheet)
            await host.settle(20)
        }

        /// Opens the Replace dialog and dismisses it with its Cancel button.
        private func dismissReplaceDialog(_ host: AcceptanceHost) async throws {
            try await openReplaceDialog(host)
            try await host.press(label: "Cancel", in: host.window.attachedSheet)
            await host.settle(20)
        }

        /// The dialog's confirm button says "Replace Sync Node", never the node ID.
        private func openReplaceDialog(_ host: AcceptanceHost) async throws {
            let showsReplace = await host.waitFor { elements in
                elements.contains { HostedAX.identifier($0) == "sync-node-replace" }
            }
            XCTAssertTrue(showsReplace, host.axDump().joined(separator: "\n"))
            try await host.press(identifier: "sync-node-replace")
            let showsDialog = await host.waitFor { _ in
                guard let sheet = host.window.attachedSheet else { return false }
                return host.elements(in: sheet).contains { HostedAX.role($0) == "AXButton" && HostedAX.texts($0).contains("Replace Sync Node") }
            }
            XCTAssertTrue(showsDialog, host.axDump().joined(separator: "\n"))
            let nodeID = try SyncNodeSettingsEnrollmentFixture().profile.nodeDeviceID.rawValue
            XCTAssertFalse(host.allTexts().contains { $0.contains(nodeID) }, "the page or dialog names the node ID")
        }

        private func hostPage(enrollment: SyncNodeEnrollmentViewModel) async throws -> AcceptanceHost {
            let fixture = try SyncNodeSettingsEnrollmentFixture()
            let session = AccountSessionViewModel(
                prepareSession: { _ in .active },
                syncNodeEnrollmentFactory: { enrollment },
                syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: fixture.profileStore(imported: true))
            )
            await activate(session)
            return hostSettings(session)
        }

        private func hostSettings(
            _ session: AccountSessionViewModel,
            nodeSettings: SyncNodeSettingsViewModel? = nil
        ) -> AcceptanceHost {
            let accountSetup = AccountSetupViewModel.connectedPreview()
            return AcceptanceHost(
                SettingsWorkspace(
                    selection: .constant(.section(.syncNode)),
                    accountSetup: accountSetup,
                    accountSessionModel: session,
                    nodeSettings: nodeSettings,
                    aiProviderSettings: .preview(),
                    aiIndexStatus: InboxViewModel.preview().aiIndexStatus,
                    auditLog: .preview(),
                    mailRules: .preview(),
                    mailLabels: .preview(),
                    maintenance: .preview(accountSetup: accountSetup)
                ),
                size: NSSize(width: 1100, height: 900)
            )
        }

        private func activate(_ session: AccountSessionViewModel) async {
            session.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
            for _ in 0 ..< 200 where session.presentation != .active { await Task.yield() }
            XCTAssertEqual(session.presentation, .active)
        }
    }

    @MainActor
    private final class SettingsEnrollmentFactory {
        private let results: [SyncNodeEnrollmentViewModel?]
        private let failure: any Error
        private(set) var calls = 0

        /// `nil` entries throw `failure`. The default is what the production factory throws
        /// when the account has no Sync Node and no Server Setup is imported.
        init(results: [SyncNodeEnrollmentViewModel?], failure: any Error = SyncNodeEnrollmentAssembly.LoadError.noSyncNode) {
            self.results = results
            self.failure = failure
        }

        func make() throws -> SyncNodeEnrollmentViewModel {
            defer { calls += 1 }
            guard let model = results[min(calls, results.count - 1)] else { throw failure }
            return model
        }
    }

    private final class RefreshCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    @MainActor
    private final class CalendarAuthorityRequests {
        var count = 0
    }
#endif
