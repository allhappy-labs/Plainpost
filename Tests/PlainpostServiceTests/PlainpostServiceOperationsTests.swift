import Foundation
import CryptoKit
import XCTest
import SQLite3
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostAI
import PlainpostCore
@testable import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostServiceRuntime
import PlainpostTestSupport
import PlainpostNotificationRuntime
import PlainpostNodeTransport
@testable import PlainpostService

final class PlainpostServiceOperationsTests: XCTestCase {
    func testReopenStartsMonitorOnceAndIsIdempotent() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let monitors = RecordingMailMonitorFactory()
        let operations = fixture.makeOperations(
            mailMonitorFactory: { monitors.make(signal: $0) }
        )

        await operations.reopenRuntimeConstruction()
        await operations.reopenRuntimeConstruction()

        XCTAssertEqual(monitors.count, 1)
        let monitor = try XCTUnwrap(monitors.monitor(at: 0))
        let startCount = await monitor.startCount
        XCTAssertEqual(startCount, 1)
        await operations.beginVaultLockdown()
    }

    func testRealtimeSignalEnqueuesIncrementalJobAndDrainsImmediately() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "realtime-secret"
        let message = serviceMessage(
            id: MessageID("message-realtime-signal"),
            threadID: ThreadID("thread-realtime-signal"),
            mailboxPath: "INBOX"
        )
        let imap = LocalIMAPServer(
            username: "realtime@example.com",
            password: password,
            message: message,
            messageUID: 42
        )
        try await imap.start()
        defer { imap.stop() }
        let account = replacingIMAPEndpoint(
            serviceAccount(
                id: "account-realtime-signal",
                username: "realtime@example.com"
            ),
            port: imap.port
        )
        try fixture.store.cacheAccounts([account])
        try await storeIMAPPassword(
            password,
            accountID: account.id,
            fixture: fixture
        )
        let monitors = RecordingMailMonitorFactory()
        let operations = fixture.makeOperations(
            mailMonitorFactory: { monitors.make(signal: $0) }
        )
        await operations.reopenRuntimeConstruction()
        let monitor = try XCTUnwrap(monitors.monitor(at: 0))

        try await monitor.emit(account.id)

        let jobs = try fixture.store.jobs(limit: 100).filter {
            $0.kind == .inboxSync
        }
        let job = try XCTUnwrap(jobs.first)
        let input = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data(job.payloadJSON.utf8)
        )
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(input.trigger, .realTimeSignal)
        XCTAssertEqual(input.scope, .incremental)
        await operations.beginVaultLockdown()
    }

    func testLockdownStopsMonitorBeforeRuntimeReferencesAreCleared() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let monitors = RecordingMailMonitorFactory(blockStops: true)
        let operations = fixture.makeOperations(
            mailMonitorFactory: { monitors.make(signal: $0) }
        )
        await operations.reopenRuntimeConstruction()
        _ = try await operations.processBackgroundJobs()
        let monitor = try XCTUnwrap(monitors.monitor(at: 0))

        let lockdown = Task { await operations.beginVaultLockdown() }
        try await waitForServiceCondition { await monitor.stopCount == 1 }

        let hasRuntimeWhileStopBlocked =
            await operations.hasBackgroundOperationRuntimeForTesting
        XCTAssertTrue(hasRuntimeWhileStopBlocked)
        await monitor.releaseStop()
        await lockdown.value
        let hasRuntimeAfterLockdown =
            await operations.hasBackgroundOperationRuntimeForTesting
        XCTAssertFalse(hasRuntimeAfterLockdown)
    }

    func testReopenAfterLockdownCreatesFreshMonitor() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let monitors = RecordingMailMonitorFactory()
        let operations = fixture.makeOperations(
            mailMonitorFactory: { monitors.make(signal: $0) }
        )

        await operations.reopenRuntimeConstruction()
        await operations.beginVaultLockdown()
        await operations.reopenRuntimeConstruction()

        XCTAssertEqual(monitors.count, 2)
        let first = try XCTUnwrap(monitors.monitor(at: 0))
        let second = try XCTUnwrap(monitors.monitor(at: 1))
        let firstStopCount = await first.stopCount
        let secondStartCount = await second.startCount
        XCTAssertEqual(firstStopCount, 1)
        XCTAssertEqual(secondStartCount, 1)
        await operations.beginVaultLockdown()
    }

    func testLockdownWaitsForMonitorStopToFinish() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let monitors = RecordingMailMonitorFactory(blockStops: true)
        let operations = fixture.makeOperations(
            mailMonitorFactory: { monitors.make(signal: $0) }
        )
        let finished = ServiceCompletionRecorder()
        await operations.reopenRuntimeConstruction()
        let monitor = try XCTUnwrap(monitors.monitor(at: 0))

        let lockdown = Task {
            await operations.beginVaultLockdown()
            await finished.finish()
        }
        try await waitForServiceCondition { await monitor.stopCount == 1 }
        let finishedWhileBlocked = await finished.isFinished
        XCTAssertFalse(finishedWhileBlocked)

        await monitor.releaseStop()
        await lockdown.value
        let finishedAfterRelease = await finished.isFinished
        XCTAssertTrue(finishedAfterRelease)
    }

    func testServiceBoundAccountClientUsesSelectedCentralOrigin() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.service.central")
        let configurationStore = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let selected = try CentralServerConfiguration(originText: "https://service-central.example:8443")
        XCTAssertTrue(try configurationStore.installSelectionIfAbsent(selected.canonicalSelectionRecord))
        let transport = ServiceOriginRecordingTransport()
        let manifest = try BootstrapKeyManifestStore(secretStore: secrets)
        let api = try XCTUnwrap(PlainpostServiceComposition.makeBoundAccountAPI(
            transport: transport,
            credentials: credentials,
            manifest: manifest,
            configurationStore: configurationStore,
            bundledDocument: nil
        ))
        let accountCredentials = try AccountSessionCredentials(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshCredential: Data(repeating: 7, count: 32),
            offlineLease: "lease"
        )
        do {
            _ = try await api.sendAccountRequest(
                method: "GET",
                path: "/v1/notification/policy",
                credentials: accountCredentials,
                device: try AccountDeviceIdentity.generate()
            )
            XCTFail("expected recording transport to stop the request")
        } catch {}

        let requestURL = await transport.lastURL
        XCTAssertEqual(requestURL?.absoluteString, "https://service-central.example:8443/v1/notification/policy")
    }

    func testDirectReconciliationValueEnforcesCentralOverrideCoordinates() throws {
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x50, count: 32))!
        XCTAssertThrowsError(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .senderSubject,
            effectiveVersion: 1, scopeVersion: 0, override: true
        ))
        XCTAssertThrowsError(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .senderSubject,
            effectiveVersion: 1, scopeVersion: 2, override: true
        ))
        XCTAssertNoThrow(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .senderSubject,
            effectiveVersion: 2, scopeVersion: 2, override: true
        ))
        XCTAssertThrowsError(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .richPreview,
            effectiveVersion: 0, scopeVersion: 0, override: false
        ))
        XCTAssertNoThrow(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .richPreview,
            effectiveVersion: 7, scopeVersion: 9, override: false
        ))
        XCTAssertThrowsError(try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .senderSubject,
            effectiveVersion: 0, scopeVersion: 1, override: false
        ))
    }

    func testDirectPolicySequencePreservesEffectiveVersionAndIndependentScopeHighWater() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-policy-sequence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "sequence@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(id: MailboxID("sequence-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x52, count: 32))!
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 11, trustEpoch: 4, trustRevision: 12,
            trustHead: Data(repeating: 0xA1, count: 32)
        )
        func install(_ mode: NodeSyncNotificationPolicyMode, effective: Int64, scope: Int64, override: Bool) throws {
            XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
                store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
                reconciliations: [DirectNotificationPolicyReconciliation(
                    assignment: assignment,
                    policy: DirectNotificationPolicyReconciliationValue(
                        logicalMailboxID: logical, mode: mode, effectiveVersion: effective,
                        scopeVersion: scope, override: override
                    )
                )]
            ))
        }
        try install(.richPreview, effective: 7, scope: 0, override: false)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyVersion, 7)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.configRevision, 12)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.directPolicyScopeVersion, 0)
        try install(.senderSubject, effective: 1, scope: 1, override: true)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyMode, "sender_subject")
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyVersion, 1)
        try install(.off, effective: 2, scope: 2, override: true)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyMode, "off")
        try install(.richPreview, effective: 7, scope: 3, override: false)
        let restored = try XCTUnwrap(store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
        XCTAssertEqual(restored.policyMode, "rich_preview")
        XCTAssertEqual(restored.policyVersion, 7)
        XCTAssertEqual(restored.configRevision, 12)
        XCTAssertEqual(restored.directPolicyScopeVersion, 3)
    }

    func testDirectReconciliationRejectsMissingAuthoritativeMailboxState() throws {
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x53, count: 32))!
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 2, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA2, count: 32)
        )
        let snapshot = DirectNotificationPolicySnapshot(
            defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "7", scopeVersion: "0", override: false),
            mailboxPolicies: [], mailboxStates: []
        )
        XCTAssertTrue(DirectNotificationConfigurationInstaller.reconciliations(
            assignments: [assignment], snapshot: snapshot, producerDeviceID: producer
        ).isEmpty)
    }

    func testDirectReconciliationRejectsAssignmentRaceWithoutWriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-assignment-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "race@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(id: MailboxID("race-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x54, count: 32))!
        let first = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 2, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA3, count: 32))
        let second = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 3, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA4, count: 32))
        let state = try DirectNotificationPolicyMailboxState(logicalMailboxID: logical, mode: .richPreview, version: "7", scopeVersion: "0", override: false)
        let snapshot = DirectNotificationPolicySnapshot(
            defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "7", scopeVersion: "0", override: false),
            mailboxPolicies: [], mailboxStates: [state]
        )
        let sequence = AssignmentSequence(values: [[first], [second]])
        let reconciled = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { await sequence.next() }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertFalse(reconciled)
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
    }

    func testDirectReconciliationRevokesRemovedMailboxAndRestoresOnlyWithNewerAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-revocation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "revocation@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(id: MailboxID("revocation-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x57, count: 32))!
        let assignment = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 3, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xB1, count: 32))
        let state = try DirectNotificationPolicyMailboxState(logicalMailboxID: logical, mode: .richPreview, version: "1", scopeVersion: "0", override: false)
        let snapshot = DirectNotificationPolicySnapshot(
            defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "1", scopeVersion: "0", override: false),
            mailboxPolicies: [], mailboxStates: [state]
        )
        let configured = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [assignment] }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertTrue(configured)
        XCTAssertNotNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))

        let missingState = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [assignment] },
            fetchSnapshot: {
                DirectNotificationPolicySnapshot(
                    defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "1", scopeVersion: "0", override: false),
                    mailboxPolicies: [], mailboxStates: []
                )
            },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertFalse(missingState)
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))

        let removed = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [] },
            fetchSnapshot: {
                DirectNotificationPolicySnapshot(
                    defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "1", scopeVersion: "0", override: false),
                    mailboxPolicies: [], mailboxStates: []
                )
            },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertFalse(removed)
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))

        let stale = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [assignment] }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertFalse(stale)
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))

        let newerAssignment = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 4, trustEpoch: 1, trustRevision: 2, trustHead: Data(repeating: 0xB2, count: 32))
        let restored = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [newerAssignment] }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertTrue(restored)
        let restoredConfiguration = try XCTUnwrap(
            store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")
        )
        XCTAssertEqual(restoredConfiguration.producerDeviceIDValue, producer)

        let switchedProducer = try AccountDeviceID("00000000-0000-4000-8000-000000000003")
        let switchedAssignment = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: switchedProducer, kind: .mac, generation: 5, trustEpoch: 1, trustRevision: 3, trustHead: Data(repeating: 0xB4, count: 32))
        let switched = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: switchedProducer,
            fetchAssignments: { [switchedAssignment] }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, switchedProducer) }
        )
        XCTAssertTrue(switched)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.producerDeviceIDValue, switchedProducer)
    }

    func testDirectReconciliationTransportFailureRetainsDurableConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "retry@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(id: MailboxID("retry-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x58, count: 32))!
        let assignment = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 3, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xB3, count: 32))
        let state = try DirectNotificationPolicyMailboxState(logicalMailboxID: logical, mode: .richPreview, version: "1", scopeVersion: "0", override: false)
        let snapshot = DirectNotificationPolicySnapshot(
            defaultPolicy: try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "1", scopeVersion: "0", override: false),
            mailboxPolicies: [], mailboxStates: [state]
        )
        let configured = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { [assignment] }, fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertTrue(configured)
        let failed = await DirectNotificationConfigurationInstaller.reconcile(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            fetchAssignments: { throw NotificationRuntimeError.unavailable },
            fetchSnapshot: { snapshot },
            currentIdentity: { (plainpostAccount, producer) }
        )
        XCTAssertFalse(failed)
        XCTAssertNotNil(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
    }

    func testDirectInstallerRejectsMissingBindingForMultipleProviderAccounts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-multiple-accounts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let accounts = [
            serviceAccount(id: "provider-local-a", username: "a@example.com"),
            serviceAccount(id: "provider-local-b", username: "b@example.com")
        ]
        try store.cacheAccounts(accounts)
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x55, count: 32))!
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA5, count: 32)
        )
        let policy = try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .richPreview, effectiveVersion: 1,
            scopeVersion: 0, override: false
        )
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount,
            producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)]
        ))
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: accounts[0].id, mailboxPath: "INBOX"))
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: accounts[1].id, mailboxPath: "INBOX"))
    }

    /// With no Sync Node, each Direct account's Inbox is named by the mailbox ID every
    /// trusted device derives for it; every account Central assigned to this Mac binds.
    func testDirectInstallerBindsEachDerivedInboxCentralAssignedToThisMac() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let accounts = [
            serviceAccount(id: "provider-local-a", username: "a@example.com"),
            serviceAccount(id: "provider-local-b", username: "b@example.com"),
            serviceAccount(id: "provider-local-c", username: "c@example.com")
        ]
        try store.cacheAccounts(accounts)
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let derived = [
            accounts[0].id: LogicalMailboxID(rawValue: Data(repeating: 0x61, count: 32))!,
            accounts[1].id: LogicalMailboxID(rawValue: Data(repeating: 0x62, count: 32))!,
            accounts[2].id: LogicalMailboxID(rawValue: Data(repeating: 0x63, count: 32))!,
        ]
        // Central assigned this Mac to the first two accounts only.
        let reconciliations = try [accounts[0], accounts[1]].map { account in
            let mailbox = try XCTUnwrap(derived[account.id])
            return DirectNotificationPolicyReconciliation(
                assignment: NotificationProducerAssignment(
                    logicalMailboxID: mailbox.rawValue, producerDeviceID: producer, kind: .mac,
                    generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA5, count: 32)
                ),
                policy: try DirectNotificationPolicyReconciliationValue(
                    logicalMailboxID: mailbox, mode: .richPreview, effectiveVersion: 1,
                    scopeVersion: 0, override: false
                )
            )
        }

        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: reconciliations, derivedInboxMailboxIDs: derived
        ))

        for account in accounts.prefix(2) {
            let configuration = try XCTUnwrap(
                store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")
            )
            XCTAssertEqual(configuration.logicalMailboxIDBytes, derived[account.id]?.rawValue)
            XCTAssertEqual(configuration.producerDeviceIDValue, producer)
        }
        XCTAssertNil(try store.notificationProducerConfiguration(accountID: accounts[2].id, mailboxPath: "INBOX"))
    }

    /// The matching key rotates (a device revoked), so the account's derived mailbox changes:
    /// the old binding is revoked and the Inbox binds to the new mailbox Central assigns.
    func testDirectInstallerRebindsAnInboxWhoseDerivedMailboxChanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-rotated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-a", username: "a@example.com")
        try store.cacheAccounts([account])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        func reconciliation(_ mailbox: LogicalMailboxID) throws -> DirectNotificationPolicyReconciliation {
            DirectNotificationPolicyReconciliation(
                assignment: NotificationProducerAssignment(
                    logicalMailboxID: mailbox.rawValue, producerDeviceID: producer, kind: .mac,
                    generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA5, count: 32)
                ),
                policy: try DirectNotificationPolicyReconciliationValue(
                    logicalMailboxID: mailbox, mode: .richPreview, effectiveVersion: 1,
                    scopeVersion: 0, override: false
                )
            )
        }
        let before = LogicalMailboxID(rawValue: Data(repeating: 0x71, count: 32))!
        let after = LogicalMailboxID(rawValue: Data(repeating: 0x72, count: 32))!
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [reconciliation(before)], derivedInboxMailboxIDs: [account.id: before]
        ))

        _ = try store.revokeNotificationProducerConfigurations(
            plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            retainedLogicalMailboxIDs: [after]
        )
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [reconciliation(after)], derivedInboxMailboxIDs: [account.id: after]
        ))

        let configuration = try XCTUnwrap(
            store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")
        )
        XCTAssertEqual(configuration.logicalMailboxIDBytes, after.rawValue)
    }

    /// Signing in (or recovering) after the service started gives it a producer without a
    /// restart; a session whose producer couldn't be built tries again once a minute.
    func testNotificationAssemblyFollowsThePlainpostAccountSession() {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var identity: String?
            var builds = 0
            var now = Date(timeIntervalSince1970: 1_000)
        }
        let state = State()
        let cache = PlainpostServiceComposition.DirectNotificationAssemblyCache(
            sessionIdentity: { state.lock.withLock { state.identity } },
            make: {
                state.lock.withLock { state.builds += 1 }
                return .init(notificationDrain: nil, install: nil)
            },
            now: { state.lock.withLock { state.now } }
        )

        _ = cache.current()
        _ = cache.current()
        XCTAssertEqual(state.builds, 1, "No session: built once")

        state.lock.withLock { state.identity = "account/device" }
        _ = cache.current()
        XCTAssertEqual(state.builds, 2, "Signing in rebuilds")
        _ = cache.current()
        XCTAssertEqual(state.builds, 2)

        state.lock.withLock { state.now = state.now.addingTimeInterval(61) }
        _ = cache.current()
        XCTAssertEqual(state.builds, 3, "A missing producer is retried after a minute")

        state.lock.withLock { state.identity = "account/other-device" }
        _ = cache.current()
        XCTAssertEqual(state.builds, 4, "A new session rebuilds")
    }

    func testDirectInstallerBootstrapsExistingZeroAuthorityInboxRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-zero-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mail.sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "zero@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(id: MailboxID("zero-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")])
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO local_notification_mailboxes (account_id, plainpost_account_id, mailbox_path, logical_mailbox_id, logical_mailbox_id_bytes, uid_validity, selected_producer_kind, policy_mode, policy_version, config_revision, config_version, producer_generation, baseline_complete, updated_at) VALUES ('provider-local-account', 'provider-local-account', 'INBOX', 'INBOX', zeroblob(32), 0, 'mac', 'off', 0, 0, 'default', 0, 0, 0)"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x56, count: 32))!
        let assignment = NotificationProducerAssignment(logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac, generation: 2, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0xA6, count: 32))
        let policy = try DirectNotificationPolicyReconciliationValue(logicalMailboxID: logical, mode: .generic, effectiveVersion: 3, scopeVersion: 0, override: false)
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)]
        ))
        let persisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
        XCTAssertEqual(persisted.plainpostAccountID, plainpostAccount)
        XCTAssertEqual(persisted.logicalMailboxIDBytes, logical.rawValue)
        XCTAssertEqual(persisted.policyMode, "generic")
        XCTAssertEqual(persisted.policyVersion, 3)
        XCTAssertEqual(persisted.configRevision, 1)
        XCTAssertEqual(persisted.directPolicyScopeVersion, 0)
    }

    func testDirectPolicyScopeDoesNotReuseLegacyConfigRevisionWhenApplyingOff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-scope-legacy-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-scope-legacy", username: "scope-legacy@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("scope-legacy-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x3B, count: 32))!
        try store.updateNotificationProducerConfiguration(
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
            configuration: NotificationProducerConfiguration(
                plainpostAccountID: plainpostAccount, logicalMailboxID: logical,
                producerDeviceID: producer, policyMode: "rich_preview", policyVersion: 7,
                configRevision: 10, producerGeneration: 4, configVersion: "legacy-rich"
            )
        )
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 4, trustEpoch: 1, trustRevision: 10, trustHead: Data(repeating: 0xA9, count: 32)
        )
        let off = try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .off, effectiveVersion: 1,
            scopeVersion: 1, override: true
        )
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: off)]
        ))
        let persisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
        XCTAssertEqual(persisted.policyMode, "off")
        XCTAssertEqual(persisted.policyVersion, 1)
        XCTAssertEqual(persisted.configRevision, 10)
        XCTAssertEqual(persisted.directPolicyScopeVersion, 1)
    }

    func testDirectInstallerPersistsEffectivePolicyAndMailboxScopeForProviderLocalAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-reconcile-red-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let providerAccount = serviceAccount(id: "provider-local-account", username: "direct@example.com")
        try store.cacheAccounts([providerAccount])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("provider-inbox"), accountID: providerAccount.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x42, count: 32))!
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 8, trustEpoch: 4, trustRevision: 10,
            trustHead: Data(repeating: 0x91, count: 32)
        )
        let policy = try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .senderSubject, effectiveVersion: 9,
            scopeVersion: 9, override: true
        )

        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount,
            producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)]
        ))
        let configuration = try XCTUnwrap(store.notificationProducerConfiguration(
            accountID: providerAccount.id, mailboxPath: "INBOX"
        ))
        XCTAssertEqual(configuration.plainpostAccountID, plainpostAccount)
        XCTAssertEqual(configuration.logicalMailboxIDBytes, logical.rawValue)
        XCTAssertEqual(configuration.policyMode, "sender_subject")
        XCTAssertEqual(configuration.policyVersion, 9)
        XCTAssertEqual(configuration.configRevision, 10)
        XCTAssertEqual(configuration.directPolicyScopeVersion, 9)
        XCTAssertEqual(configuration.producerGeneration, 8)
    }

    func testDirectInstallerDoesNotRollBackStaleGenerationOrPolicyAndRejectsEqualConflict() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-monotonic-red-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "direct@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("provider-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x43, count: 32))!
        func reconciliation(generation: UInt64, version: String, scope: String, mode: NodeSyncNotificationPolicyMode, trustHeadByte: UInt8 = 0x92) throws -> DirectNotificationPolicyReconciliation {
            let assignment = NotificationProducerAssignment(
                logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
                generation: generation, trustEpoch: 4, trustRevision: 10,
                trustHead: Data(repeating: trustHeadByte, count: 32)
            )
            let policy = try DirectNotificationPolicyReconciliationValue(
                logicalMailboxID: logical, mode: mode, effectiveVersion: Int64(version)!,
                scopeVersion: Int64(scope)!, override: true
            )
            return DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)
        }

        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 8, version: "9", scope: "9", mode: .generic)]
        ))
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 8, version: "8", scope: "8", mode: .richPreview)]
        ))
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 7, version: "10", scope: "10", mode: .richPreview)]
        ))
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 8, version: "10", scope: "10", mode: .generic, trustHeadByte: 0x93)]
        ))
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 8, version: "9", scope: "9", mode: .off)]
        ))
        XCTAssertFalse(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            reconciliations: [try reconciliation(generation: 8, version: "9", scope: "9", mode: .generic, trustHeadByte: 0x93)]
        ))
        let configuration = try XCTUnwrap(store.notificationProducerConfiguration(
            accountID: account.id, mailboxPath: "INBOX"
        ))
        XCTAssertEqual(configuration.policyMode, "generic")
        XCTAssertEqual(configuration.policyVersion, 9)
        XCTAssertEqual(configuration.configRevision, 10)
        XCTAssertEqual(configuration.directPolicyScopeVersion, 9)
        XCTAssertEqual(configuration.producerGeneration, 8)
    }

    func testDirectNotificationConfigurationInstallerPersistsAuthoritativeAssignment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "00000000-0000-4000-8000-000000000001", username: "notification-config@example.com")
        try store.cacheAccounts([account])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000001")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let mailbox = Data(repeating: 0x42, count: 32)
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox,
            producerDeviceID: producer,
            kind: .mac,
            generation: 7,
            trustEpoch: 3,
            trustRevision: 9,
            trustHead: Data(repeating: 0x91, count: 32)
        )

        let policy = try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: LogicalMailboxID(rawValue: mailbox)!, mode: .richPreview,
            effectiveVersion: 1, scopeVersion: 1, override: true
        )
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store,
            plainpostAccountID: plainpostAccount,
            producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)]
        ))
        let configuration = try XCTUnwrap(
            store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")
        )
        XCTAssertEqual(configuration.plainpostAccountID, plainpostAccount)
        XCTAssertEqual(configuration.logicalMailboxIDBytes, mailbox)
        XCTAssertEqual(configuration.producerDeviceIDValue, producer)
        XCTAssertEqual(configuration.producerGeneration, 7)
        XCTAssertEqual(configuration.configRevision, 9)
        XCTAssertEqual(configuration.directPolicyScopeVersion, 1)
        XCTAssertEqual(configuration.policyMode, "rich_preview")
    }

    func testDirectNotificationConfigurationInstallerReconcilesMultipleBoundMailboxesWithoutLocalAccountUUID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-multi-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "multi@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("inbox-local"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("archive-local"), accountID: account.id, name: "Archive", path: "Archive", specialUse: "\\Archive")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let oldHead = Data(repeating: 0x11, count: 32)
        for (path, mailboxValue) in [("INBOX", UInt8(0x42)), ("Archive", UInt8(0x43))] {
            let logical = LogicalMailboxID(rawValue: Data(repeating: mailboxValue, count: 32))!
            try store.updateNotificationProducerConfiguration(
                accountID: account.id, mailboxPath: path, uidValidity: 0,
                configuration: NotificationProducerConfiguration(
                    plainpostAccountID: plainpostAccount, logicalMailboxID: logical,
                    producerDeviceID: producer, producerKind: "mac", policyMode: "rich_preview",
                    policyVersion: 1, configRevision: 2, producerGeneration: 3,
                    configVersion: "old-\(path)"
                )
            )
        }
        let assignments = [
            NotificationProducerAssignment(logicalMailboxID: Data(repeating: 0x42, count: 32), producerDeviceID: producer, kind: .mac, generation: 8, trustEpoch: 4, trustRevision: 10, trustHead: oldHead),
            NotificationProducerAssignment(logicalMailboxID: Data(repeating: 0x43, count: 32), producerDeviceID: producer, kind: .mac, generation: 9, trustEpoch: 4, trustRevision: 10, trustHead: oldHead)
        ]

        let policies = try assignments.map { assignment in
            DirectNotificationPolicyReconciliation(
                assignment: assignment,
                policy: try DirectNotificationPolicyReconciliationValue(
                    logicalMailboxID: LogicalMailboxID(rawValue: assignment.logicalMailboxID)!,
                    mode: .richPreview, effectiveVersion: 2, scopeVersion: 2, override: true
                )
            )
        }
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount,
            producerDeviceID: producer, reconciliations: policies
        ))
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.producerGeneration, 8)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "Archive")?.producerGeneration, 9)
        XCTAssertEqual(try store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.plainpostAccountID, plainpostAccount)
    }

    func testDirectInstallerRestoresRevokedBindingsAcrossAccountsAndProducerRotation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-revoked-bindings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let accounts = [
            serviceAccount(id: "provider-local-a", username: "a@example.com"),
            serviceAccount(id: "provider-local-b", username: "b@example.com")
        ]
        try store.cacheAccounts(accounts)
        for account in accounts {
            try store.cacheMailboxes([
                Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
                Mailbox(id: MailboxID("\(account.id.rawValue)-archive"), accountID: account.id, name: "Archive", path: "Archive", specialUse: "\\Archive")
            ])
        }
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producerA = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let producerB = try AccountDeviceID("00000000-0000-4000-8000-000000000003")
        let bindings: [(AccountID, String, LogicalMailboxID)] = accounts.enumerated().flatMap { index, account in
            [
                (account.id, "INBOX", LogicalMailboxID(rawValue: Data(repeating: UInt8(0x60 + index * 2), count: 32))!),
                (account.id, "Archive", LogicalMailboxID(rawValue: Data(repeating: UInt8(0x61 + index * 2), count: 32))!)
            ]
        }
        for (accountID, path, logical) in bindings {
            try store.updateNotificationProducerConfiguration(
                accountID: accountID, mailboxPath: path, uidValidity: 0,
                configuration: NotificationProducerConfiguration(
                    plainpostAccountID: plainpostAccount, logicalMailboxID: logical,
                    producerDeviceID: producerA, producerKind: "mac", policyMode: "rich_preview",
                    policyVersion: 1, configRevision: 0, producerGeneration: 1,
                    configVersion: "initial-\(logical.rawValue.base64EncodedString())"
                )
            )
        }
        XCTAssertEqual(try store.revokeNotificationProducerConfigurations(
            plainpostAccountID: plainpostAccount, producerDeviceID: producerA,
            retainedLogicalMailboxIDs: []
        ), bindings.count)
        for (accountID, path, _) in bindings {
            XCTAssertNil(try store.notificationProducerConfiguration(accountID: accountID, mailboxPath: path))
            XCTAssertNotNil(try store.notificationProducerConfigurationForReconciliation(accountID: accountID, mailboxPath: path))
        }

        func reconciliations(for producer: AccountDeviceID, generation: UInt64) throws -> [DirectNotificationPolicyReconciliation] {
            try bindings.map { _, _, logical in
                DirectNotificationPolicyReconciliation(
                    assignment: NotificationProducerAssignment(
                        logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
                        generation: generation, trustEpoch: 1, trustRevision: generation,
                        trustHead: Data(repeating: UInt8(generation), count: 32)
                    ),
                    policy: try DirectNotificationPolicyReconciliationValue(
                        logicalMailboxID: logical, mode: .richPreview,
                        effectiveVersion: 1, scopeVersion: 0, override: false
                    )
                )
            }
        }
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producerA,
            reconciliations: try reconciliations(for: producerA, generation: 2)
        ))
        for (accountID, path, logical) in bindings {
            let restored = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: path))
            XCTAssertEqual(restored.logicalMailboxIDBytes, logical.rawValue)
            XCTAssertEqual(restored.producerDeviceIDValue, producerA)
        }

        XCTAssertEqual(try store.revokeNotificationProducerConfigurations(
            plainpostAccountID: plainpostAccount, producerDeviceID: producerA,
            retainedLogicalMailboxIDs: []
        ), bindings.count)
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producerB,
            reconciliations: try reconciliations(for: producerB, generation: 3)
        ))
        for (accountID, path, logical) in bindings {
            let rotated = try XCTUnwrap(store.notificationProducerConfiguration(accountID: accountID, mailboxPath: path))
            XCTAssertEqual(rotated.logicalMailboxIDBytes, logical.rawValue)
            XCTAssertEqual(rotated.producerDeviceIDValue, producerB)
        }
    }

    func testDirectCompositionSyncCreatesEligibleSQLiteNotificationOutboxForFreshInboxMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-sync-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-account", username: "me@example.com")
        try store.cacheAccounts([account])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x51, count: 32))!
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("provider-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 7, trustEpoch: 3, trustRevision: 4,
            trustHead: Data(repeating: 0x61, count: 32)
        )
        let policy = try DirectNotificationPolicyReconciliationValue(
            logicalMailboxID: logical, mode: .richPreview, effectiveVersion: 1,
            scopeVersion: 1, override: true
        )
        XCTAssertTrue(try DirectNotificationConfigurationInstaller.install(
            store: store, plainpostAccountID: plainpostAccount,
            producerDeviceID: producer,
            reconciliations: [DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)]
        ))
        let configuration = try XCTUnwrap(store.notificationProducerConfiguration(
            accountID: account.id, mailboxPath: "INBOX"
        ))
        XCTAssertEqual(configuration.plainpostAccountID, plainpostAccount)
        XCTAssertEqual(
            try store.recordMailboxGeneration(accountID: account.id, mailboxPath: "INBOX", uidValidity: 1),
            .initialBaseline
        )
        try store.markMailboxBaselineComplete(accountID: account.id, mailboxPath: "INBOX", uidValidity: 1)
        XCTAssertEqual(
            try store.recordMailboxGeneration(accountID: account.id, mailboxPath: "INBOX", uidValidity: 1),
            .unchanged
        )
        let server = LocalIMAPServer(username: account.username, password: "secret", message: PlainpostFixtures.aliceMessage)
        try await server.start()
        defer { server.stop() }
        let sync = IMAPSyncService(
            client: PlaintextIMAPClient(host: "127.0.0.1", port: server.port), cache: store
        )
        let result = try await sync.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: account.id, email: account.email,
                username: account.username, password: "secret"
            ),
            options: IMAPSyncOptions(
                mailboxPaths: ["INBOX"], incrementalOnly: true, notificationEligible: true,
                notificationConfiguration: configuration
            )
        )
        XCTAssertEqual(result.syncedMessageCount, 1)
        let publication = try XCTUnwrap(
            store.claimNotificationPublication(now: Date(), leaseToken: "integration", leaseDuration: 60)
        )
        XCTAssertEqual(publication.producerGeneration, 7)
        XCTAssertEqual(publication.logicalMailboxIDBytes, logical.rawValue)
    }

    func testInjectedCompositionReconcilesDirectPolicyThroughServiceHookAndLocalIMAP() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-production-direct-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("plainpost.sqlite")
        let seedStore = try SQLiteMailStore(path: databaseURL.path)
        try seedStore.migrate()
        let account = serviceAccount(id: "provider-local-production", username: "production@example.com")
        try seedStore.cacheAccounts([account])
        try seedStore.cacheMailboxes([
            Mailbox(id: MailboxID("production-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x6A, count: 32))!
        let recipientID = try AccountDeviceID("00000000-0000-4000-8000-000000000010")
        let recipientAgreement = P256.KeyAgreement.PrivateKey()
        let producerSigning = P256.Signing.PrivateKey()
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 7, trustEpoch: 2, trustRevision: 4,
            trustHead: Data(repeating: 0x71, count: 32)
        )
        let policySequence = ProductionDirectPolicySequence()
        let relay = ProductionRecordingRelay()
        let smtp = LocalSMTPServer(username: account.username, password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let assembly = SQLiteCredentialVaultAssembly(store: seedStore, provider: FixedVaultKeyProvider())
        try await assembly.unlockForeground(prompt: "Production direct-policy test setup")
        try await assembly.vault.store(
            Data("secret".utf8),
            for: CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password")
        )
        await assembly.session.lock()
        let composition = try makeInjectedComposition(
            databaseURL: databaseURL,
            assembly: assembly,
            directNotificationAssemblyFactory: { serviceStore in
                let producerForDrain = NotificationProducer(
                    coordination: ProductionCoordinationClient(
                        recipientID: recipientID,
                        recipientAgreementPublicKey: recipientAgreement.publicKey.x963Representation
                    ),
                    verifier: ProductionAssignmentVerifier(),
                    previewBuilder: PPN2NotificationPreviewBuilder(
                        producerDeviceID: producer,
                        producerSigningPublicKey: producerSigning.publicKey.x963Representation,
                        sign: { try producerSigning.signature(for: $0).rawRepresentation },
                        snapshot: { source, _ in
                            guard let message = try serviceStore.messageSummary(id: source.messageID) else {
                                throw NotificationRuntimeError.staleAssignment
                            }
                            let digest = SHA256.hash(data: Data(message.body.utf8))
                            return NotificationMessageSnapshot(
                                mailboxToken: source.logicalMailboxID,
                                threadToken: message.threadID?.rawValue ?? "none",
                                messageToken: message.id.rawValue,
                                sender: message.from.rawValue,
                                subject: message.subject,
                                preview: message.preview,
                                badge: 1,
                                messageDigest: Data(digest),
                                replayID: Data(SHA256.hash(data: Data(message.id.rawValue.utf8))),
                                collapseDigest: Data(SHA256.hash(data: Data(source.logicalMailboxIDBytes)))
                            )
                        },
                        trust: { _, _ in
                            try NotificationTrustCoordinates(
                                epoch: assignment.trustEpoch,
                                revision: assignment.trustRevision,
                                head: assignment.trustHead
                            )
                        }
                    )
                )
                let drain = NotificationDrain(store: serviceStore, producer: producerForDrain, relay: relay)
                return PlainpostServiceComposition.makeDirectNotificationAssembly(
                    store: serviceStore, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
                    notificationDrain: drain,
                    fetchAssignments: { [assignment] },
                    fetchSnapshot: { try await policySequence.snapshot() },
                    currentIdentity: { (plainpostAccount, producer) }
                )
            }
        )
        try await composition.lifecycle.unlock(prompt: "Production direct-policy test", capability: .app)

        // Complete the initial baseline through the same durable store the
        // service operation uses; every subsequent loop is a real operation
        // hook followed by Local IMAP and NotificationDrain processing.
        XCTAssertEqual(try composition.store.recordMailboxGeneration(accountID: account.id, mailboxPath: "INBOX", uidValidity: 1), .initialBaseline)
        try composition.store.markMailboxBaselineComplete(accountID: account.id, mailboxPath: "INBOX", uidValidity: 1)
        let modes: [(NodeSyncNotificationPolicyMode, Int64, Int64, Bool, String)] = [
            (.richPreview, 1, 0, false, "rich_preview"),
            (.senderSubject, 1, 1, true, "sender_subject"),
            (.generic, 2, 2, true, "generic"),
            (.off, 3, 3, true, "off"),
            (.richPreview, 5, 4, false, "rich_preview")
        ]
        var publicationCount = 0
        for (index, mode) in modes.enumerated() {
            await policySequence.set(defaultVersion: index == 4 ? "5" : "1", mode: mode.0, version: mode.1, scope: mode.2, override: mode.3)
            let message = MessageSummary(
                id: MessageID("production-policy-\(index)"), threadID: nil,
                from: EmailAddress("sender-\(index)@example.com"), subject: "Subject \(index)",
                preview: "Preview \(index)", body: "Body \(index)", smartCategory: .personal
            )
            let smtpData = "From: \(message.from.rawValue)\r\nTo: \(account.email.rawValue)\r\nSubject: \(message.subject)\r\n\r\n\(message.body)"
            try await MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: smtp.port).send(
                username: account.username,
                password: "secret",
                from: message.from,
                to: [account.email],
                data: smtpData
            )
            let acceptedSMTPMessages = await smtp.acceptedMessages()
            XCTAssertEqual(acceptedSMTPMessages.count, index + 1 + (index >= 4 ? 1 : 0))
            let accepted = try XCTUnwrap(acceptedSMTPMessages.last)
            let messageUID = index + 2 + (index >= 4 ? 1 : 0)
            let peer = LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS"],
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")],
                uidValidity: 1, messageUID: messageUID, messageData: Data(accepted.data.utf8)
            )
            let server = LocalIMAPServer(
                username: account.username, password: "secret", message: message,
                messageUID: messageUID, peer: peer
            )
            try await server.start()
            defer { server.stop() }
            try composition.store.cacheAccounts([replacingIMAPEndpoint(account, port: server.port)])
            _ = try await composition.operations.perform(.inboxSync(
                PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
            ))
            _ = try await composition.operations.processBackgroundJobs()
            let persisted = try composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")
            XCTAssertEqual(persisted?.policyMode, mode.4)
            XCTAssertEqual(persisted?.policyVersion, mode.1 == 5 ? 5 : mode.1)
            XCTAssertEqual(persisted?.configRevision, 4)
            XCTAssertEqual(persisted?.directPolicyScopeVersion, mode.2)
            if mode.0 == .off {
                let relayCount = await relay.count()
                XCTAssertEqual(relayCount, publicationCount)
                await policySequence.set(defaultVersion: "1", mode: .richPreview, version: 1, scope: 3, override: true)
                let staleMessage = MessageSummary(
                    id: MessageID("production-policy-stale-rich"), threadID: nil,
                    from: EmailAddress("stale@example.com"), subject: "Stale Rich",
                    preview: "Stale body", body: "Stale body", smartCategory: .personal
                )
                let staleSMTPData = "From: \(staleMessage.from.rawValue)\r\nTo: \(account.email.rawValue)\r\nSubject: \(staleMessage.subject)\r\n\r\n\(staleMessage.body)"
                try await MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: smtp.port).send(
                    username: account.username, password: "secret", from: staleMessage.from,
                    to: [account.email], data: staleSMTPData
                )
                let acceptedStaleMessages = await smtp.acceptedMessages()
                let acceptedStale = try XCTUnwrap(acceptedStaleMessages.last)
                let staleServer = LocalIMAPServer(
                    username: account.username, password: "secret", message: staleMessage, messageUID: index + 3,
                    peer: LocalIMAPPeerResponse(
                        capabilities: ["IMAP4rev1", "UIDPLUS"],
                        mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")],
                        uidValidity: 1, messageUID: index + 3, messageData: Data(acceptedStale.data.utf8)
                    )
                )
                try await staleServer.start()
                try composition.store.cacheAccounts([replacingIMAPEndpoint(account, port: staleServer.port)])
                _ = try await composition.operations.perform(.inboxSync(
                    PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
                ))
                _ = try await composition.operations.processBackgroundJobs()
                staleServer.stop()
                let staleRelayCount = await relay.count()
                XCTAssertEqual(staleRelayCount, publicationCount)
                XCTAssertEqual(
                    try composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyMode,
                    "off"
                )
            } else {
                publicationCount += 1
                let envelopeData = await relay.lastEnvelope()
                let envelope = try XCTUnwrap(envelopeData)
                let decoded = try RichNotificationEnvelope.open(
                    envelope,
                    recipientAgreementPrivateKey: recipientAgreement.rawRepresentation,
                    authority: try RichNotificationEnvelope.Authority(
                        recipientDeviceID: recipientID,
                        producerDeviceID: producer,
                        producerSigningPublicKey: producerSigning.publicKey.x963Representation
                    ),
                    now: Date().addingTimeInterval(1)
                )
                XCTAssertEqual(decoded.header.policyVersion, UInt16(mode.1))
                switch mode.0 {
                case .richPreview:
                    XCTAssertEqual(decoded.content.sender, message.from.rawValue)
                    XCTAssertEqual(decoded.content.subject, message.subject)
                    XCTAssertEqual(decoded.content.preview, message.body)
                case .senderSubject:
                    XCTAssertEqual(decoded.content.sender, message.from.rawValue)
                    XCTAssertEqual(decoded.content.subject, message.subject)
                    XCTAssertEqual(decoded.content.preview, "")
                case .generic:
                    XCTAssertEqual(decoded.content.sender, "Plainpost")
                    XCTAssertEqual(decoded.content.subject, "New mail is available.")
                    XCTAssertEqual(decoded.content.preview, "")
                case .off:
                    XCTFail("Off must not publish an envelope.")
                }
            }
        }
        XCTAssertEqual(try composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX")?.policyMode, "rich_preview")
    }

    func testInjectedCompositionReopensDirectPolicyAndPreservesOffEligibility() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-production-direct-policy-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("plainpost.sqlite")
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        let account = serviceAccount(id: "provider-local-production-restart", username: "restart@example.com")
        try seed.cacheAccounts([account])
        try seed.cacheMailboxes([
            Mailbox(id: MailboxID("restart-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x6A, count: 32))!
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 7, trustEpoch: 2, trustRevision: 4,
            trustHead: Data(repeating: 0x71, count: 32)
        )
        let policySequence = ProductionDirectPolicySequence()
        await policySequence.set(defaultVersion: "3", mode: .off, version: 3, scope: 3, override: true)

        func makeComposition() async throws -> PlainpostServiceComposition {
            let compositionStore = try SQLiteMailStore(path: databaseURL.path)
            try compositionStore.migrate()
            let assembly = SQLiteCredentialVaultAssembly(store: compositionStore, provider: FixedVaultKeyProvider())
            try await assembly.unlockForeground(prompt: "Production direct-policy restart setup")
            return try makeInjectedComposition(
                databaseURL: databaseURL,
                assembly: assembly,
                directNotificationAssemblyFactory: { serviceStore in
                    PlainpostServiceComposition.makeDirectNotificationAssembly(
                        store: serviceStore,
                        plainpostAccountID: plainpostAccount,
                        producerDeviceID: producer,
                        notificationDrain: nil,
                        fetchAssignments: { [assignment] },
                        fetchSnapshot: { try await policySequence.snapshot() },
                        currentIdentity: { (plainpostAccount, producer) }
                    )
                }
            )
        }

        // The first composition persists the Off scope/effective version via
        // the same operation hook used after a real service unlock.
        do {
            let composition = try await makeComposition()
            try await composition.lifecycle.unlock(prompt: "Production direct-policy restart", capability: .app)
            await composition.operations.reopenRuntimeConstruction()
            _ = try await composition.operations.processBackgroundJobs()
            let persisted = try XCTUnwrap(composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
            XCTAssertEqual(persisted.policyMode, "off")
            XCTAssertEqual(persisted.policyVersion, 3)
            XCTAssertEqual(persisted.directPolicyScopeVersion, 3)
            XCTAssertEqual(persisted.producerGeneration, 7)
            await composition.lifecycle.lock()
            await composition.lifecycle.shutdown()
        }

        // Drop the first store/service objects, rebuild through production(),
        // and reload the authoritative assignment/snapshot from the same DB.
        do {
            let composition = try await makeComposition()
            try await composition.lifecycle.unlock(prompt: "Production direct-policy restart", capability: .app)
            await composition.operations.reopenRuntimeConstruction()
            _ = try await composition.operations.processBackgroundJobs()
            let reopened = try XCTUnwrap(composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
            XCTAssertEqual(reopened.policyMode, "off")
            XCTAssertEqual(reopened.policyVersion, 3)
            XCTAssertEqual(reopened.directPolicyScopeVersion, 3)
            XCTAssertEqual(reopened.producerGeneration, 7)
            XCTAssertNil(try composition.store.claimNotificationPublication(now: Date(), leaseToken: "restart", leaseDuration: 60))

            // An older Rich snapshot is a stale authority and must not
            // restore publication eligibility after the restart.
            await policySequence.set(defaultVersion: "1", mode: .richPreview, version: 1, scope: 2, override: false)
            _ = try await composition.operations.processBackgroundJobs()
            let stale = try XCTUnwrap(composition.store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
            XCTAssertEqual(stale.policyMode, "off")
            XCTAssertEqual(stale.policyVersion, 3)
            XCTAssertEqual(stale.directPolicyScopeVersion, 3)
            XCTAssertNil(try composition.store.claimNotificationPublication(now: Date(), leaseToken: "stale", leaseDuration: 60))
            await composition.lifecycle.lock()
            await composition.lifecycle.shutdown()
        }
    }

    func testProductionDirectReconciliationSerializesEmptyObservationBeforeNewerAssignment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-reconcile-serialization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        let account = serviceAccount(id: "provider-local-serialization", username: "serialization@example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("serialization-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
        ])
        let plainpostAccount = try PlainpostAccountID("00000000-0000-4000-8000-000000000099")
        let producer = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x6B, count: 32))!
        try store.updateNotificationProducerConfiguration(
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
            configuration: NotificationProducerConfiguration(
                plainpostAccountID: plainpostAccount, logicalMailboxID: logical,
                producerDeviceID: producer, policyMode: "rich_preview", policyVersion: 1,
                configRevision: 1, producerGeneration: 1, configVersion: "initial"
            )
        )
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: logical.rawValue, producerDeviceID: producer, kind: .mac,
            generation: 2, trustEpoch: 1, trustRevision: 2, trustHead: Data(repeating: 0x72, count: 32)
        )
        let source = DirectReconciliationRaceSource(assignment: assignment, logicalMailboxID: logical)
        let assembly = PlainpostServiceComposition.makeDirectNotificationAssembly(
            store: store, plainpostAccountID: plainpostAccount, producerDeviceID: producer,
            notificationDrain: nil,
            fetchAssignments: { await source.assignments() },
            fetchSnapshot: { await source.snapshot() },
            currentIdentity: { (plainpostAccount, producer) }
        )

        let oldObservation = Task { await assembly.install?() }
        await source.waitUntilOldObservationBlocks()
        let newerObservation = Task { await assembly.install?() }
        try await Task.sleep(nanoseconds: 200_000_000)
        await source.releaseOldObservation()
        _ = await oldObservation.value
        _ = await newerObservation.value

        let persisted = try XCTUnwrap(store.notificationProducerConfiguration(accountID: account.id, mailboxPath: "INBOX"))
        XCTAssertEqual(persisted.producerGeneration, 2)
        XCTAssertEqual(persisted.policyMode, "sender_subject")
    }

    func testProductionCompositionRecoversDeletionIntentBeforeRuntimeReopens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-composition-deletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("plainpost.sqlite")
        let provider = FixedVaultKeyProvider()
        let initial = try SQLiteMailStore(path: databaseURL.path)
        try initial.migrate()
        let assembly = SQLiteCredentialVaultAssembly(store: initial, provider: provider)
        try await assembly.unlockForeground(prompt: "Initial test unlock")
        let account = serviceAccount(id: "composition-crash-delete", username: "crash@example.com")
        try initial.cacheAccounts([account])
        try await assembly.vault.store(
            Data("imap-secret-never-journaled".utf8),
            for: CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password")
        )
        try await assembly.vault.store(
            Data("smtp-secret-never-journaled".utf8),
            for: CredentialRecordKey(rawValue: "account:\(account.id.rawValue):smtp-password")
        )
        let crashing = try SQLiteMailStore(
            path: databaseURL.path,
            accountDeletionFailpoint: { _ in
                throw PlainpostError.validationFailed("simulated process termination")
            }
        )
        do {
            try await crashing.deleteAccountData(accountID: account.id, credentials: assembly.vault)
            XCTFail("Expected the post-vault-removal failpoint.")
        } catch {}
        XCTAssertTrue(initial.accounts.contains { $0.id == account.id })
        await assembly.session.lock()

        let recoveryStore = try SQLiteMailStore(path: databaseURL.path)
        try recoveryStore.migrate()
        let recoveryAssembly = SQLiteCredentialVaultAssembly(
            store: recoveryStore,
            provider: provider
        )
        let operations = PlainpostServiceOperations(
            applicationSupportURL: directory,
            store: recoveryStore,
            assembly: recoveryAssembly
        )
        let lifecycle = PlainpostServiceLifecycleCoordinator(
            vaultSession: recoveryAssembly.session,
            prepareForegroundUnlock: { try await recoveryAssembly.prepareForegroundUnlock() },
            beginVaultLockdown: { await operations.beginVaultLockdown() },
            confirmVaultLocked: { await operations.confirmVaultLocked() },
            recoverAfterUnlock: { try await recoveryAssembly.recoverPendingAccountDeletions() },
            reopenRuntimeConstruction: { await operations.reopenRuntimeConstruction() }
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: lifecycle,
            performForegroundOperation: { try await operations.perform($0) },
            processBackgroundJobs: { try await operations.processBackgroundJobs() },
            performSmartInboxBatch: { try await operations.performSmartInboxBatch($0) },
            sendBrowserApprovedReply: { try await operations.sendBrowserApprovedReply(jobID: $0) },
            syncDraftToServer: { try await operations.syncDraftToServer(draftID: $0, mailbox: $1) }
        )
        let composition = PlainpostServiceComposition(
            listener: listener, lifecycle: lifecycle, operations: operations, store: recoveryStore
        )
        try await composition.lifecycle.unlock(prompt: "Restart unlock", capability: .app)

        let reopened = try SQLiteMailStore(path: databaseURL.path)
        try reopened.migrate()
        XCTAssertFalse(reopened.accounts.contains { $0.id == account.id })
        let status = try await composition.lifecycle.status()
        XCTAssertEqual(status.availability, .unlocked)
    }

    func testDecodedAccountRequestCannotExposeOrComparePasswords() {
        let imapPassword = "decoded-imap-top-secret"
        let smtpPassword = "decoded-smtp-top-secret"
        let payload = PlainpostAccountSetupPayload(
            displayName: "Example",
            email: "me@example.com",
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            username: "me@example.com",
            sentMailbox: "Sent",
            imapPassword: imapPassword,
            smtpPassword: smtpPassword
        )

        let request = PlainpostServiceOperations.accountRequest(payload)
        let snapshots = [
            String(describing: request),
            String(reflecting: request),
            Mirror(reflecting: request).children
                .map { String(describing: $0.value) }
                .joined(separator: "|"),
        ]

        let requestType: Any.Type = AccountSetupRequest.self
        XCTAssertFalse(requestType is any Equatable.Type)
        for snapshot in snapshots {
            XCTAssertFalse(snapshot.contains(imapPassword))
            XCTAssertFalse(snapshot.contains(smtpPassword))
        }
    }

    func testDeleteAccountUsesSemanticVaultAndNeverConstructsRemoteTransport() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let target = serviceAccount(
            id: "account-delete-target",
            username: "delete-target@example.com"
        )
        let retained = serviceAccount(
            id: "account-delete-retained",
            username: "delete-retained@example.com"
        )
        try fixture.store.cacheAccounts([target, retained])
        let targetIMAP = CredentialRecordKey(
            rawValue: "account:\(target.id.rawValue):imap-password"
        )
        let targetSMTP = CredentialRecordKey(
            rawValue: "account:\(target.id.rawValue):smtp-password"
        )
        let retainedIMAP = CredentialRecordKey(
            rawValue: "account:\(retained.id.rawValue):imap-password"
        )
        let retainedSMTP = CredentialRecordKey(
            rawValue: "account:\(retained.id.rawValue):smtp-password"
        )
        try await fixture.assembly.vault.store(Data("target-imap".utf8), for: targetIMAP)
        try await fixture.assembly.vault.store(Data("target-smtp".utf8), for: targetSMTP)
        try await fixture.assembly.vault.store(Data("retained-imap".utf8), for: retainedIMAP)
        try await fixture.assembly.vault.store(Data("retained-smtp".utf8), for: retainedSMTP)
        let transports = TransportFactoryCallProbe()
        let operations = fixture.makeOperations(
            accountRuntimeFactory: {
                AccountSetupService(
                    store: fixture.store,
                    credentials: fixture.assembly.vault,
                    imapClientFactory: { host, port in
                        transports.recordIMAP()
                        return MailTransportClientFactory.imapClient(host: host, port: port)
                    },
                    smtpClientFactory: { host, port in
                        transports.recordSMTP()
                        return MailTransportClientFactory.smtpClient(host: host, port: port)
                    }
                )
            }
        )
        await operations.reopenRuntimeConstruction()

        let result = try await operations.perform(
            .deleteAccount(
                PlainpostAccountDeletionPayload(accountID: target.id.rawValue)
            )
        )

        guard case .deleteAccount = result else {
            return XCTFail("Expected account deletion result.")
        }
        XCTAssertFalse(fixture.store.accounts.contains { $0.id == target.id })
        XCTAssertTrue(fixture.store.accounts.contains { $0.id == retained.id })
        let deletedIMAP = try await fixture.assembly.vault.load(targetIMAP)
        let deletedSMTP = try await fixture.assembly.vault.load(targetSMTP)
        let remainingIMAP = try await fixture.assembly.vault.load(retainedIMAP)
        let remainingSMTP = try await fixture.assembly.vault.load(retainedSMTP)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
        XCTAssertEqual(remainingIMAP, Data("retained-imap".utf8))
        XCTAssertEqual(remainingSMTP, Data("retained-smtp".utf8))
        XCTAssertEqual(transports.snapshot(), .init(imap: 0, smtp: 0))
    }

    func testDeleteAccountRejectsNewForegroundWorkAndWaitsForExistingWork() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = serviceAccount(
            id: "account-delete-foreground-drain",
            username: "delete-foreground@example.com"
        )
        try fixture.store.cacheAccounts([account])
        let gate = BlockingAccountTestGate()
        let monitors = RecordingMailMonitorFactory()
        let operations = fixture.makeOperations(
            accountRuntimeFactory: {
                AccountSetupService(
                    store: fixture.store,
                    credentials: fixture.assembly.vault,
                    imapClientFactory: { _, _ in BlockingAccountTestIMAPClient(gate: gate) },
                    smtpClientFactory: { _, _ in UnsupportedSMTPSecurityClient() }
                )
            },
            mailMonitorFactory: { monitors.make(signal: $0) }
        )
        await operations.reopenRuntimeConstruction()
        let monitor = try XCTUnwrap(monitors.monitor(at: 0))
        let setup = PlainpostAccountSetupPayload(
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            username: account.username,
            sentMailbox: account.sentMailbox,
            imapPassword: "foreground-secret",
            smtpPassword: "foreground-secret"
        )

        let existingWork = Task {
            try await operations.perform(.accountTest(setup))
        }
        await gate.waitUntilStarted()
        let deletion = Task {
            try await operations.perform(
                .deleteAccount(
                    PlainpostAccountDeletionPayload(accountID: account.id.rawValue)
                )
            )
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertTrue(fixture.store.accounts.contains { $0.id == account.id })
        do {
            _ = try await operations.perform(.accountTest(setup))
            XCTFail("Expected new foreground work to be rejected during deletion.")
        } catch {
            XCTAssertEqual(error as? PlainpostServiceClientError, .operationFailed)
        }
        _ = try? await monitor.emit(account.id)
        XCTAssertFalse(
            try fixture.store.jobs(limit: 20).contains { $0.kind == .inboxSync },
            "realtime monitoring must not enqueue work during account deletion"
        )

        await gate.release()
        do {
            _ = try await existingWork.value
            XCTFail("Expected the blocking account test to fail after release.")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .connectionFailed)
        }
        guard case .deleteAccount = try await deletion.value else {
            return XCTFail("Expected account deletion result.")
        }
        XCTAssertFalse(fixture.store.accounts.contains { $0.id == account.id })
    }

    func testDeleteAccountWaitsForInFlightBackgroundDrainBeforeDeleting() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let gate = BlockingIMAPSessionStartGate()
        let password = "delete-background-secret"
        let message = serviceMessage(
            id: MessageID("message-delete-background"),
            threadID: ThreadID("thread-delete-background"),
            mailboxPath: "INBOX"
        )
        let imap = LocalIMAPServer(
            username: "delete-background@example.com",
            password: password,
            message: message,
            messageUID: 94,
            onSessionStart: gate.block
        )
        try await imap.start()
        defer {
            gate.open()
            imap.stop()
        }
        let account = replacingIMAPEndpoint(
            serviceAccount(
                id: "account-delete-background-drain",
                username: "delete-background@example.com"
            ),
            port: imap.port
        )
        try fixture.store.cacheAccounts([account])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "delete background",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 94,
            notificationEligible: false
        )
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let input = PlainpostMailboxFlagInput(
            messageID: message.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 94,
            desiredSeen: false
        )
        _ = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "delete-background-drain"
            )
        )
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: RecordingBackgroundJobWakeScheduler()
        )
        await operations.reopenRuntimeConstruction()
        let drain = Task { try await operations.processBackgroundJobs() }
        let sessionStarted = await gate.waitUntilStarted()
        XCTAssertTrue(sessionStarted)

        let deletion = Task {
            try await operations.perform(
                .deleteAccount(
                    PlainpostAccountDeletionPayload(accountID: account.id.rawValue)
                )
            )
        }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(fixture.store.accounts.contains { $0.id == account.id })

        gate.open()
        _ = try await drain.value
        guard case .deleteAccount = try await deletion.value else {
            return XCTFail("Expected account deletion result.")
        }
        XCTAssertFalse(fixture.store.accounts.contains { $0.id == account.id })
    }

    func testDeleteAccountCancelsAndAwaitsIncrementalSharedClassifierBeforePreservingRetainedWork() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let target = serviceAccount(
            id: "account-delete-incremental-target",
            username: "incremental-target@example.com"
        )
        let retained = serviceAccount(
            id: "account-delete-incremental-retained",
            username: "incremental-retained@example.com"
        )
        try fixture.store.cacheAccounts([target, retained])
        for (account, suffix, uid) in [(target, "target", 201), (retained, "retained", 202)] {
            let message = serviceMessage(
                id: MessageID("message-incremental-\(suffix)"),
                threadID: ThreadID("thread-incremental-\(suffix)"),
                mailboxPath: "INBOX"
            )
            try fixture.store.cacheThread(MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "incremental \(suffix)",
                participantEmails: [message.from]
            ))
            _ = try fixture.store.commitIncomingMessage(
                message,
                metadata: emptySearchMetadata,
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: uid,
                notificationEligible: false
            )
        }
        let provider = DeletionHoldingClassificationProvider()
        let operations = fixture.makeOperations(
            operationRuntimeFactory: {
                LocalOperationRuntime(
                    store: fixture.store,
                    credentials: fixture.assembly.vault,
                    aiProviderResolver: { _ in provider }
                )
            }
        )
        await operations.reopenRuntimeConstruction()
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id,
            smartInboxRunRequest: .init(
                mode: .incremental,
                scope: .allAccounts,
                requestedLabelID: nil
            ),
            enqueueOnly: true
        )

        _ = try await operations.perform(.ai(input))
        await provider.waitUntilClassificationStarts()
        let sharedJob = try XCTUnwrap(
            fixture.store.jobs(limit: 20).first { $0.kind == .aiOperation }
        )
        let deletionProbe = AccountDeletionCompletionProbe()
        let deletion = Task {
            do {
                let result = try await operations.perform(
                    .deleteAccount(.init(accountID: target.id.rawValue))
                )
                await deletionProbe.finish(result: result)
            } catch {
                await deletionProbe.finish(error: error)
            }
        }
        defer {
            deletion.cancel()
            Task { await provider.releaseClassification() }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var cancellationStarted = await provider.cancellationStarted()
        while !cancellationStarted, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            cancellationStarted = await provider.cancellationStarted()
        }
        let deletionCompleted = await deletionProbe.isCompleted
        XCTAssertTrue(cancellationStarted)
        XCTAssertFalse(deletionCompleted)
        XCTAssertTrue(fixture.store.accounts.contains { $0.id == target.id })

        await provider.releaseClassification()
        _ = await deletion.value
        let deletionResult = try await deletionProbe.result()
        guard case .deleteAccount = deletionResult else {
            return XCTFail("Expected account deletion result.")
        }
        XCTAssertFalse(fixture.store.accounts.contains { $0.id == target.id })
        XCTAssertTrue(fixture.store.accounts.contains { $0.id == retained.id })
        let retainedJob = try fixture.store.job(id: sharedJob.id)
        XCTAssertEqual(retainedJob.id, sharedJob.id)
        XCTAssertEqual(retainedJob.state, .queued)
        XCTAssertNil(retainedJob.leaseToken)
        XCTAssertEqual(retainedJob.progress?.total, 1)

        _ = try await operations.perform(.ai(input))
        for _ in 0..<200 {
            if try fixture.store.job(id: sharedJob.id).state == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try fixture.store.job(id: sharedJob.id).state, .completed)
    }

    func testVaultLockdownOwnsTransitionWhileAccountDeletionIsWaiting() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = serviceAccount(
            id: "account-delete-lockdown",
            username: "delete-lockdown@example.com"
        )
        try fixture.store.cacheAccounts([account])
        let gate = BlockingAccountTestGate()
        let scheduler = RecordingBackgroundJobWakeScheduler()
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: scheduler,
            accountRuntimeFactory: {
                AccountSetupService(
                    store: fixture.store,
                    credentials: fixture.assembly.vault,
                    imapClientFactory: { _, _ in BlockingAccountTestIMAPClient(gate: gate) },
                    smtpClientFactory: { _, _ in UnsupportedSMTPSecurityClient() }
                )
            }
        )
        await operations.reopenRuntimeConstruction()
        let setup = PlainpostAccountSetupPayload(
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            username: account.username,
            sentMailbox: account.sentMailbox,
            imapPassword: "lockdown-secret",
            smtpPassword: "lockdown-secret"
        )
        let existingWork = Task { try await operations.perform(.accountTest(setup)) }
        await gate.waitUntilStarted()
        let deletion = Task {
            try await operations.perform(
                .deleteAccount(
                    PlainpostAccountDeletionPayload(accountID: account.id.rawValue)
                )
            )
        }
        for _ in 0..<200 { await Task.yield() }
        let lockdown = Task { await operations.beginVaultLockdown() }
        for _ in 0..<200 { await Task.yield() }

        do {
            _ = try await operations.perform(.accountTest(setup))
            XCTFail("Expected lockdown to close runtime construction before waiting.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }

        await gate.release()
        _ = try? await existingWork.value
        guard case .deleteAccount = try await deletion.value else {
            return XCTFail("Expected the admitted deletion to complete.")
        }
        await lockdown.value
        await operations.confirmVaultLocked()
        let scheduledAt = await scheduler.scheduledAt
        XCTAssertNil(scheduledAt)
        do {
            _ = try await operations.perform(.accountTest(setup))
            XCTFail("Expected runtime construction to remain locked.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }
        do {
            _ = try await operations.perform(
                .deleteAccount(
                    PlainpostAccountDeletionPayload(accountID: account.id.rawValue)
                )
            )
            XCTFail("Expected deletion admitted after lockdown closure to fail.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }
    }

    func testMarkUnreadPersistsExactlyOneDurableIntentAndOnlySignalsWork() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        try fixture.store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try fixture.store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(true),
            metadata: .init(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 47,
            notificationEligible: false
        )
        let scheduler = RecordingMailboxFlagScheduler()
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL,
            store: fixture.store,
            assembly: fixture.assembly,
            mailboxFlagScheduler: scheduler
        )
        await operations.reopenRuntimeConstruction()

        let result = try await operations.perform(
            .markUnread(
                PlainpostMailActionPayload(
                    messageID: PlainpostFixtures.aliceMessage.id.rawValue
                )
            )
        )

        XCTAssertEqual(result.kind, .markUnread)
        XCTAssertEqual(
            try fixture.store.desiredSeenState(
                messageID: PlainpostFixtures.aliceMessage.id
            ),
            false
        )
        XCTAssertEqual(
            try fixture.store.jobs(limit: 10).filter { $0.kind == .mailboxFlag }.count,
            1
        )
        let calls = scheduler.snapshot()
        XCTAssertEqual(calls.schedule, 0)
        XCTAssertEqual(calls.signal, 1)
    }

    func testBackgroundAgentOperationDrainsDurableJobsToTerminalState()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let draft = try fixture.store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try fixture.store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Agent drain verification"
        )
        let decision = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let job = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(decision),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "agent-drain:\(request.id.rawValue)"
            )
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let result = try await operations.processBackgroundJobs()

        XCTAssertEqual(result.processedJobCount, 1)
        XCTAssertEqual(result.recoveredJobCount, 0)
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .completed)
        XCTAssertEqual(
            try fixture.store.sendRequest(id: request.id).status,
            .denied
        )
    }

    func testBackgroundAgentContinuesAfterOneDurableJobFails()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let draft = try fixture.store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try fixture.store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Continue-after-failure verification"
        )
        let decision = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let decisionPayload = String(
            decoding: try JSONEncoder().encode(decision),
            as: UTF8.self
        )
        let failedJob = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: decisionPayload,
                priority: 200,
                maxAttempts: 1,
                idempotencyKey: "agent-drain-invalid"
            )
        )
        try await fixture.store.databasePool.write { database in
            try database.execute(
                sql: "UPDATE durable_jobs SET payload_json = '{}' WHERE id = ?",
                arguments: [failedJob.id]
            )
        }
        let successfulJob = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(decision),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "agent-drain-valid"
            )
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let result = try await operations.processBackgroundJobs()

        XCTAssertEqual(result.processedJobCount, 2)
        XCTAssertEqual(
            try fixture.store.job(id: failedJob.id).state,
            .failed
        )
        XCTAssertEqual(
            try fixture.store.job(id: successfulJob.id).state,
            .completed
        )
        XCTAssertEqual(
            try fixture.store.sendRequest(id: request.id).status,
            .denied
        )
    }

    func testBackgroundAgentSchedulesAndExecutesEarliestRetryWake()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = serviceAccount(
            id: "account-retry-wake",
            username: "retry@example.com"
        )
        let unreachableAccount = Account(
            id: account.id,
            displayName: account.displayName,
            email: account.email,
            username: account.username,
            sentMailbox: account.sentMailbox,
            imapHost: "127.0.0.1",
            imapPort: 1,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort
        )
        let message = serviceMessage(
            id: MessageID("message-retry-wake"),
            threadID: ThreadID("thread-retry-wake"),
            mailboxPath: "INBOX"
        )
        try fixture.store.cacheAccounts([unreachableAccount])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "retry wake",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 91,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            "retry-secret",
            accountID: account.id,
            fixture: fixture
        )
        let input = PlainpostMailboxFlagInput(
            messageID: message.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 91,
            desiredSeen: true
        )
        let job = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 3,
                idempotencyKey: "agent-retry-wake"
            )
        )
        let scheduler = RecordingBackgroundJobWakeScheduler()
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: scheduler
        )
        await operations.reopenRuntimeConstruction()

        let result = try await operations.processBackgroundJobs()
        let afterFailure = try fixture.store.job(id: job.id)
        let scheduledAt = await scheduler.scheduledAt

        XCTAssertEqual(result.processedJobCount, 1)
        XCTAssertEqual(afterFailure.state, .queued)
        XCTAssertEqual(scheduledAt, afterFailure.availableAt)

        try await Task.sleep(
            for: .seconds(
                max(
                    0,
                    afterFailure.availableAt.timeIntervalSinceNow
                        + 0.05
                )
            )
        )
        await scheduler.fire()

        let afterWake = try fixture.store.job(id: job.id)
        let rescheduledAt = await scheduler.scheduledAt
        XCTAssertEqual(afterWake.attempt, 2)
        XCTAssertEqual(afterWake.state, .queued)
        XCTAssertEqual(
            rescheduledAt,
            afterWake.availableAt
        )
    }

    func testReopenRearmsPersistedRetryAfterLockAndServiceRestart()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let job = try await enqueueFailingMailboxFlagJob(
            fixture: fixture,
            suffix: "lifecycle"
        )
        let clock = MutableTestDateProvider(
            Date().addingTimeInterval(1)
        )
        let originalScheduler =
            RecordingBackgroundJobWakeScheduler()
        let originalOperations = fixture.makeOperations(
            backgroundJobWakeScheduler: originalScheduler,
            dateProvider: clock.now
        )
        await originalOperations.reopenRuntimeConstruction()

        let firstDrain =
            try await originalOperations.processBackgroundJobs()
        let afterFailure = try fixture.store.job(id: job.id)

        XCTAssertEqual(firstDrain.processedJobCount, 1)
        XCTAssertEqual(afterFailure.state, .queued)
        XCTAssertEqual(afterFailure.attempt, 1)
        let originalScheduledAt =
            await originalScheduler.scheduledAt
        XCTAssertEqual(
            originalScheduledAt,
            afterFailure.availableAt
        )

        await originalOperations.beginVaultLockdown()
        await originalOperations.confirmVaultLocked()
        let cancelledScheduledAt =
            await originalScheduler.scheduledAt
        XCTAssertNil(cancelledScheduledAt)

        clock.set(
            afterFailure.availableAt.addingTimeInterval(1)
        )
        let restartedScheduler =
            RecordingBackgroundJobWakeScheduler()
        let restartedOperations = fixture.makeOperations(
            backgroundJobWakeScheduler: restartedScheduler,
            dateProvider: clock.now
        )

        await restartedOperations.reopenRuntimeConstruction()

        let restartedScheduledAt =
            await restartedScheduler.scheduledAt
        XCTAssertEqual(
            restartedScheduledAt,
            afterFailure.availableAt
        )
        await restartedScheduler.fire()

        let afterRestartedWake = try fixture.store.job(id: job.id)
        XCTAssertEqual(afterRestartedWake.attempt, 2)
        XCTAssertEqual(afterRestartedWake.state, .queued)
        let rescheduledAt =
            await restartedScheduler.scheduledAt
        XCTAssertEqual(
            rescheduledAt,
            afterRestartedWake.availableAt
        )
    }

    func testJobBecomingDueBetweenDrainAndWakeQueryContinuesCurrentDrainOnce()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let draft = try fixture.store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try fixture.store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Due-boundary wake verification"
        )
        let decision = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let drainTime = Date()
        let dueTime = drainTime.addingTimeInterval(60)
        let queryTime = dueTime.addingTimeInterval(1)
        let job = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(decision),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "agent-due-boundary",
                availableAt: dueTime
            )
        )
        let clock = SequencedTestDateProvider([
            drainTime,
            queryTime,
        ])
        let scheduler = RecordingBackgroundJobWakeScheduler()
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: scheduler,
            dateProvider: clock.now
        )
        await operations.reopenRuntimeConstruction()

        let initialDrain =
            try await operations.processBackgroundJobs()

        XCTAssertEqual(initialDrain.processedJobCount, 1)
        let completed = try fixture.store.job(id: job.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.attempt, 1)
        let fireCount = await scheduler.fireCount
        let scheduledAfterDrain = await scheduler.scheduledAt
        XCTAssertEqual(fireCount, 0)
        XCTAssertNil(scheduledAfterDrain)
        XCTAssertEqual(
            try fixture.store.sendRequest(id: request.id).status,
            .denied
        )
    }

    func testWakeEnteringBeforeFlightCleanupRunsOneAggregatedSuccessorDrain()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let draft = try fixture.store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try fixture.store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Reentrant wake successor verification"
        )
        let decision = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let now = Date().addingTimeInterval(1)
        let clock = MutableTestDateProvider(now)
        let scheduler =
            ReentrantBeforeReturnBackgroundJobWakeScheduler()
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: scheduler,
            dateProvider: clock.now
        )
        await operations.reopenRuntimeConstruction()
        let futureJob = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(decision),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "agent-reentrant-future",
                availableAt: now.addingTimeInterval(3_600)
            )
        )

        let firstTask = Task {
            try await operations.processBackgroundJobs()
        }
        let replacementBlocked =
            await scheduler.waitUntilFutureReplacementIsBlocked()
        XCTAssertTrue(replacementBlocked)

        let dueJob = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .denySend,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(decision),
                    as: UTF8.self
                ),
                priority: 200,
                maxAttempts: 1,
                idempotencyKey: "agent-reentrant-due",
                availableAt: now
            )
        )
        await scheduler.fireWhileReplacementIsBlocked()
        let reentrantActionStarted =
            await scheduler.waitUntilReentrantActionStarted()
        XCTAssertTrue(reentrantActionStarted)

        let joinedCall = BackgroundDrainCallProbe()
        let joinedTask = Task {
            await joinedCall.markStarted()
            do {
                await joinedCall.record(
                    try await operations.processBackgroundJobs()
                )
            } catch {
                await joinedCall.record(error)
            }
        }
        await joinedCall.waitUntilStarted()
        for _ in 0..<200 {
            await Task.yield()
        }
        await scheduler.releaseFutureReplacement()

        let firstResult = try await firstTask.value
        await joinedTask.value
        let reentrantActionCompleted =
            await scheduler.waitUntilReentrantActionCompleted()

        XCTAssertTrue(reentrantActionCompleted)
        XCTAssertEqual(
            firstResult,
            PlainpostBackgroundJobResult(
                recoveredJobCount: 0,
                processedJobCount: 1
            )
        )
        let joinedResult = await joinedCall.result
        XCTAssertEqual(joinedResult, firstResult)
        let joinedError = await joinedCall.errorDescription
        XCTAssertNil(joinedError)
        XCTAssertEqual(
            try fixture.store.job(id: dueJob.id).state,
            .completed
        )
        XCTAssertEqual(
            try fixture.store.job(id: dueJob.id).attempt,
            1
        )
        XCTAssertEqual(
            try fixture.store.job(id: futureJob.id).state,
            .queued
        )
        XCTAssertEqual(
            try fixture.store.job(id: futureJob.id).attempt,
            0
        )
        XCTAssertEqual(
            try fixture.store.sendRequest(id: request.id).status,
            .denied
        )
        let futureReplacementCount =
            await scheduler.futureReplacementCount
        let reentrantActionCount =
            await scheduler.reentrantActionCount
        XCTAssertEqual(futureReplacementCount, 2)
        XCTAssertEqual(reentrantActionCount, 1)
    }

    func testImmediateWakeAndExplicitAgentCallShareOneInFlightDrain()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let gate = BlockingIMAPSessionStartGate()
        let password = "single-flight-secret"
        let message = serviceMessage(
            id: MessageID("message-single-flight"),
            threadID: ThreadID("thread-single-flight"),
            mailboxPath: "INBOX"
        )
        let imap = LocalIMAPServer(
            username: "single-flight@example.com",
            password: password,
            message: message,
            messageUID: 93,
            onSessionStart: gate.block
        )
        try await imap.start()
        defer {
            gate.open()
            imap.stop()
        }
        let account = Account(
            id: AccountID("account-single-flight"),
            displayName: "Single Flight",
            email: EmailAddress("single-flight@example.com"),
            username: "single-flight@example.com",
            sentMailbox: "Sent",
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1",
            smtpPort: 1
        )
        try fixture.store.cacheAccounts([account])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "single flight",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 93,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            password,
            accountID: account.id,
            fixture: fixture
        )
        let input = PlainpostMailboxFlagInput(
            messageID: message.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 93,
            desiredSeen: false
        )
        let job = try fixture.store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "agent-single-flight"
            )
        )
        let scheduler = RecordingBackgroundJobWakeScheduler()
        let operations = fixture.makeOperations(
            backgroundJobWakeScheduler: scheduler
        )
        await operations.reopenRuntimeConstruction()

        let wakeTask = Task {
            await scheduler.fire()
        }
        let sessionStarted = await gate.waitUntilStarted()
        XCTAssertTrue(sessionStarted)

        let explicitCall = BackgroundDrainCallProbe()
        let explicitTask = Task {
            await explicitCall.markStarted()
            do {
                await explicitCall.record(
                    try await operations.processBackgroundJobs()
                )
            } catch {
                await explicitCall.record(error)
            }
        }
        await explicitCall.waitUntilStarted()
        for _ in 0..<200 {
            await Task.yield()
        }

        let completedWhileWakeWasBlocked =
            await explicitCall.isCompleted
        XCTAssertFalse(completedWhileWakeWasBlocked)

        gate.open()
        await wakeTask.value
        await explicitTask.value

        let recordedResult = await explicitCall.result
        let explicitResult = try XCTUnwrap(recordedResult)
        let errorDescription =
            await explicitCall.errorDescription
        XCTAssertNil(errorDescription)
        XCTAssertEqual(explicitResult.processedJobCount, 1)
        let completed = try fixture.store.job(id: job.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.attempt, 1)
        XCTAssertEqual(imap.loginAttempts.count, 1)
    }

    func testAccountScopedSmartInboxBatchUsesServiceVaultAndRealIMAP()
        async throws
    {
        let password = "service-smart-batch-secret"
        let message = PlainpostFixtures.aliceMessage.withSeen(true)
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: message,
            extraMailboxes: [.init(path: "Archive")]
        )
        try await imap.start()
        defer { imap.stop() }
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = Account(
            id: AccountID("account-smart-batch"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            username: "me@example.com",
            sentMailbox: "Sent",
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1",
            smtpPort: 1
        )
        try fixture.store.cacheAccounts([account])
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        try await fixture.assembly.vault.store(
            Data(password.utf8),
            for: CredentialRecordKey(
                rawValue:
                    "account:\(account.id.rawValue):imap-password"
            )
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let result = try await operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(
                accountID: account.id.rawValue,
                category: "seen",
                action: "archive_read",
                archiveMailbox: "Archive"
            )
        )

        XCTAssertEqual(result.affectedMessageIDs, [message.id.rawValue])
        XCTAssertEqual(result.archiveMailbox, "Archive")
        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertTrue(imap.deletedUIDs.contains(1))
        XCTAssertEqual(imap.expungeCount, 1)
    }

    func testCanonicalArchiveUsesPersistedSourceMailboxUIDValidityAndUID()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "canonical-archive-secret"
        let account = serviceAccount(
            id: "account-canonical-archive",
            username: "archive@example.com"
        )
        let message = serviceMessage(
            id: MessageID(
                IMAPSyncService.canonicalMessageID(
                    accountID: account.id,
                    rfcMessageID: "<canonical-archive@example.com>"
                )
            ),
            threadID: ThreadID("thread-canonical-archive"),
            mailboxPath: "Projects/Receipts"
        )
        let imap = LocalIMAPServer(
            username: account.username,
            password: password,
            message: message,
            uidValidity: 7_777,
            messageUID: 42
        )
        try await imap.start()
        defer { imap.stop() }
        let routedAccount = replacingIMAPEndpoint(account, port: imap.port)
        try fixture.store.cacheAccounts([routedAccount])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "canonical archive",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "Projects/Receipts",
            uidValidity: 7_777,
            uid: 42,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            password,
            accountID: account.id,
            fixture: fixture
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let operationResult = try await operations.perform(
            .archive(
                PlainpostMailActionPayload(
                    messageID: message.id.rawValue,
                    archiveMailbox: "Processed/2026"
                )
            )
        )

        XCTAssertEqual(imap.selectedMailboxes, ["Projects/Receipts"])
        XCTAssertEqual(
            imap.copyAttempts,
            [LocalIMAPCopyAttempt(uid: 42, mailbox: "Processed/2026")]
        )
        XCTAssertEqual(imap.deletedUIDs, [42])
        XCTAssertEqual(imap.expungeCount, 1)
        guard case .archive(let result) = operationResult else {
            return XCTFail("Expected archive result.")
        }
        XCTAssertEqual(result.messageID, message.id.rawValue)
        XCTAssertEqual(result.mailboxPath, "Processed/2026")
        XCTAssertEqual(
            fixture.store.messages.first(where: { $0.id == message.id })?
                .mailboxPath,
            "Processed/2026"
        )
    }

    func testCanonicalDeleteUsesPersistedSourceMailboxUIDValidityAndUID()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "canonical-delete-secret"
        let account = serviceAccount(
            id: "account-canonical-delete",
            username: "delete@example.com"
        )
        let message = serviceMessage(
            id: MessageID(
                IMAPSyncService.canonicalMessageID(
                    accountID: account.id,
                    rfcMessageID: "<canonical-delete@example.com>"
                )
            ),
            threadID: ThreadID("thread-canonical-delete"),
            mailboxPath: "All Mail"
        )
        let imap = LocalIMAPServer(
            username: account.username,
            password: password,
            message: message,
            uidValidity: 9_001,
            messageUID: 73,
            extraMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        try await imap.start()
        defer { imap.stop() }
        let routedAccount = replacingIMAPEndpoint(account, port: imap.port)
        try fixture.store.cacheAccounts([routedAccount])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "canonical delete",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "All Mail",
            uidValidity: 9_001,
            uid: 73,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            password,
            accountID: account.id,
            fixture: fixture
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        _ = try await operations.perform(
            .delete(
                PlainpostMailActionPayload(
                    messageID: message.id.rawValue
                )
            )
        )

        // Delete moves to Trash: copy from the persisted source, then
        // expunge exactly that UID there.
        XCTAssertEqual(imap.selectedMailboxes, ["All Mail"])
        XCTAssertEqual(imap.copyAttempts, [LocalIMAPCopyAttempt(uid: 73, mailbox: "Trash")])
        XCTAssertEqual(imap.deletedUIDs, [73])
        XCTAssertEqual(imap.expungeCount, 1)
        XCTAssertEqual(try fixture.store.membership(for: message.id).mailboxPath, "Trash")
    }

    func testDeleteErasesOnlyWithExplicitPermanentAndOnlyInTrash()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "permanent-delete-secret"
        let account = serviceAccount(id: "account-permanent-delete", username: "permanent@example.com")
        let message = serviceMessage(
            id: MessageID("msg_permanent_delete"),
            threadID: ThreadID("thread-permanent-delete"),
            mailboxPath: "Trash"
        )
        let imap = LocalIMAPServer(
            username: account.username, password: password, message: message,
            uidValidity: 9_002, messageUID: 74
        )
        try await imap.start()
        defer { imap.stop() }
        try fixture.store.cacheAccounts([replacingIMAPEndpoint(account, port: imap.port)])
        try fixture.store.cacheThread(MailThread(
            id: try XCTUnwrap(message.threadID), accountID: account.id,
            subjectNormalized: "permanent delete", participantEmails: [message.from]
        ))
        _ = try fixture.store.commitIncomingMessage(
            message, metadata: emptySearchMetadata, accountID: account.id,
            mailboxPath: "Trash", uidValidity: 9_002, uid: 74, notificationEligible: false
        )
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        // A plain delete (a retry, or a Delete from a list that isn't Trash) never erases.
        guard case .delete(let plain) = try await operations.perform(
            .delete(PlainpostMailActionPayload(messageID: message.id.rawValue))
        ) else { return XCTFail("expected a delete result") }
        XCTAssertEqual(plain.deleteOutcome, .alreadyInTrash)
        XCTAssertFalse(plain.isDeleted)
        XCTAssertEqual(imap.expungeCount, 0)
        XCTAssertTrue(imap.selectedMailboxes.isEmpty, "settled without the server")

        guard case .delete(let erased) = try await operations.perform(
            .delete(PlainpostMailActionPayload(messageID: message.id.rawValue, permanent: true))
        ) else { return XCTFail("expected a delete result") }
        XCTAssertEqual(erased.deleteOutcome, .deletedPermanently)
        XCTAssertTrue(erased.isDeleted)
        XCTAssertEqual(imap.selectedMailboxes, ["Trash"])
        XCTAssertEqual(imap.deletedUIDs, [74])
        XCTAssertEqual(imap.expungeCount, 1)
    }

    /// A Node-backed account in fallback, with one message in `mailbox` on a
    /// server that has MOVE and UIDPLUS and lists `serverMailboxes`.
    private func nodeFallbackDeleteFixture(
        _ name: String, mailbox: String, serverMailboxes: [LocalIMAPPeerResponse.Mailbox]
    ) async throws -> (ServiceOperationsFixture, LocalIMAPServer, PlainpostServiceOperations, MessageID) {
        let fixture = try await ServiceOperationsFixture()
        let password = "\(name)-secret"
        let account = serviceAccount(id: "account-\(name)", username: "\(name)@example.com")
        let message = serviceMessage(id: MessageID("msg_\(name)"), threadID: ThreadID("thread-\(name)"), mailboxPath: mailbox)
        let imap = LocalIMAPServer(
            username: account.username, password: password, message: message,
            peer: LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"],
                mailboxes: [.init(path: mailbox)] + serverMailboxes,
                uidValidity: 9_100, messageUID: 75,
                messageData: Data("Subject: fallback\r\n\r\nbody".utf8)
            )
        )
        try await imap.start()
        try fixture.store.cacheAccounts([replacingIMAPEndpoint(account, port: imap.port)])
        try fixture.store.cacheThread(MailThread(
            id: try XCTUnwrap(message.threadID), accountID: account.id,
            subjectNormalized: name, participantEmails: [message.from]
        ))
        _ = try fixture.store.commitIncomingMessage(
            message, metadata: emptySearchMetadata, accountID: account.id,
            mailboxPath: mailbox, uidValidity: 9_100, uid: 75, notificationEligible: false
        )
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let direct = try fixture.store.mailSource(accountID: account.id)
        let node = try fixture.store.replaceMailSource(direct.nodeBacked(
            nodeID: "30000000-0000-4000-8000-000000000802",
            logicalMailboxID: String(repeating: "B", count: 42) + "A",
            providerIdentity: account.username
        ), expectedGeneration: direct.generation)
        try fixture.store.replaceMailSource(node.withMode(.fallback), expectedGeneration: node.generation)
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()
        return (fixture, imap, operations, message.id)
    }

    func testServiceDeleteActsOnTheShownCopyOfASelfAddressedMessage() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "self-addressed-secret"
        let account = serviceAccount(id: "account-self-addressed", username: "self@example.com")
        let message = serviceMessage(
            id: MessageID("msg_self_addressed"), threadID: ThreadID("thread-self-addressed"), mailboxPath: "INBOX"
        )
        let imap = LocalIMAPServer(
            username: account.username, password: password, message: message,
            peer: LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"],
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox"), .init(path: "Sent", specialUse: "\\Sent"),
                            .init(path: "Trash", specialUse: "\\Trash")],
                uidValidity: 9_200, messageUID: 76,
                messageData: Data("Subject: to myself\r\n\r\nbody".utf8)
            )
        )
        try await imap.start()
        defer { imap.stop() }
        try fixture.store.cacheAccounts([replacingIMAPEndpoint(account, port: imap.port)])
        try fixture.store.cacheThread(MailThread(
            id: try XCTUnwrap(message.threadID), accountID: account.id,
            subjectNormalized: "to myself", participantEmails: [message.from]
        ))
        // Synced as sync does it: the Inbox copy, then the Sent copy (which wins the message row).
        for mailbox in ["INBOX", "Sent"] {
            _ = try fixture.store.commitIncomingMessage(
                message.withMailboxPath(mailbox), metadata: emptySearchMetadata, accountID: account.id,
                mailboxPath: mailbox, uidValidity: 9_200, uid: 76, notificationEligible: false
            )
        }
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        guard case .delete(let result) = try await operations.perform(
            .delete(PlainpostMailActionPayload(messageID: message.id.rawValue, sourceMailbox: "INBOX"))
        ) else { return XCTFail("expected a delete result") }

        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(imap.selectedMailboxes, ["INBOX"])
        XCTAssertEqual(imap.moves, [LocalIMAPCopyAttempt(uid: 76, mailbox: "Trash")])
        XCTAssertEqual(try fixture.store.actionMembership(for: message.id, shownIn: "Sent").uid, 76, "the Sent copy stays")

        // A mailbox with no copy refuses before the server.
        do {
            _ = try await operations.perform(
                .archive(PlainpostMailActionPayload(messageID: message.id.rawValue, sourceMailbox: "INBOX"))
            )
            XCTFail("the Inbox copy is gone; nothing else may be archived in its place")
        } catch {}
        XCTAssertEqual(imap.selectedMailboxes, ["INBOX"])
    }

    func testNodeBackedAccountRefusesASourceMailboxInsteadOfIgnoringIt() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-source", mailbox: "INBOX", serverMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        defer { imap.stop(); fixture.cleanup() }

        for operation in [
            PlainpostForegroundOperation.delete(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: "INBOX")),
            .archive(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: "INBOX")),
        ] {
            do {
                _ = try await operations.perform(operation)
                XCTFail("a source mailbox must not be silently ignored")
            } catch PlainpostError.validationFailed(let text) {
                XCTAssertEqual(text, MailActionRefusal.noSourceMailboxWithSyncNode.message)
            }
        }
        XCTAssertTrue(imap.selectedMailboxes.isEmpty)
    }

    func testNodeBackedAccountRefusesDeletePermanently() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-permanent", mailbox: "Trash", serverMailboxes: []
        )
        defer { imap.stop(); fixture.cleanup() }

        do {
            _ = try await operations.perform(
                .delete(PlainpostMailActionPayload(messageID: messageID.rawValue, permanent: true))
            )
            XCTFail("the Sync Node never erases, and its fallback mustn't either")
        } catch PlainpostError.validationFailed {}
        XCTAssertTrue(imap.selectedMailboxes.isEmpty)
        XCTAssertEqual(imap.expungeCount, 0)
    }

    /// The agent path from the final review: archive into Trash, then a
    /// permanent delete before any sync, on a server whose mailboxes share
    /// one UIDVALIDITY (so the Inbox UID would match a message in Trash).
    private func archiveIntoTrashThenErase(capabilities: [String]) async throws -> (LocalIMAPServer, Error?) {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "agent-path-secret"
        let account = serviceAccount(id: "account-agent-path", username: "agent@example.com")
        let message = serviceMessage(id: MessageID("msg_agent_path"), threadID: ThreadID("thread-agent-path"), mailboxPath: "INBOX")
        let imap = LocalIMAPServer(
            username: account.username, password: password, message: message,
            peer: LocalIMAPPeerResponse(
                capabilities: capabilities,
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox"), .init(path: "Trash", specialUse: "\\Trash")],
                uidValidity: 9_300, messageUID: 7,
                messageData: Data("Subject: agent\r\n\r\nbody".utf8)
            )
        )
        try await imap.start()
        try fixture.store.cacheAccounts([replacingIMAPEndpoint(account, port: imap.port)])
        try fixture.store.cacheThread(MailThread(
            id: try XCTUnwrap(message.threadID), accountID: account.id,
            subjectNormalized: "agent", participantEmails: [message.from]
        ))
        try fixture.store.cacheMailboxes([Mailbox(
            id: MailboxID("agent-trash"), accountID: account.id, name: "Trash", path: "Trash", specialUse: "\\Trash"
        )])
        _ = try fixture.store.commitIncomingMessage(
            message, metadata: emptySearchMetadata, accountID: account.id,
            mailboxPath: "INBOX", uidValidity: 9_300, uid: 7, notificationEligible: false
        )
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        _ = try await operations.perform(.archive(PlainpostMailActionPayload(messageID: message.id.rawValue, archiveMailbox: "Trash")))
        do {
            _ = try await operations.perform(.delete(PlainpostMailActionPayload(messageID: message.id.rawValue, permanent: true)))
            return (imap, nil)
        } catch {
            return (imap, error)
        }
    }

    func testArchiveIntoTrashThenPermanentDeleteErasesTheCopyByItsNewUID() async throws {
        let (imap, error) = try await archiveIntoTrashThenErase(capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"])
        defer { imap.stop() }
        XCTAssertNil(error)
        XCTAssertEqual(imap.uidCommands, [
            #"MOVE 7 "Trash""#, #"STORE 501 +FLAGS.SILENT (\Deleted)"#, "EXPUNGE 501",
        ], "the erase names the Trash copy's UID, never the Inbox UID 7")
    }

    func testArchiveIntoTrashWithoutCOPYUIDThenPermanentDeleteFailsClosed() async throws {
        let (imap, error) = try await archiveIntoTrashThenErase(capabilities: ["IMAP4rev1", "UIDPLUS"])
        defer { imap.stop() }
        XCTAssertNotNil(error, "an unknown Trash UID must not be guessed")
        XCTAssertEqual(imap.uidCommands, [
            #"COPY 7 "Trash""#, #"STORE 7 +FLAGS.SILENT (\Deleted)"#, "EXPUNGE 7",
        ], "only the archive's own expunge of the Inbox copy; nothing erased in Trash")
    }

    // MARK: Archive goes to the account's own Archive (Gmail: All Mail)

    private static let gmailServerFolders: [LocalIMAPPeerResponse.Mailbox] = [
        .init(path: "[Gmail]/All Mail", specialUse: "\\All"), .init(path: "[Gmail]/Trash", specialUse: "\\Trash"),
    ]

    /// A Direct account on a Gmail-like server (INBOX, All Mail, Trash; no
    /// Archive) whose cached folder list matches it.
    private func gmailDirectFixture(
        _ name: String, serverFolders: [LocalIMAPPeerResponse.Mailbox] = gmailServerFolders
    ) async throws -> (ServiceOperationsFixture, LocalIMAPServer, PlainpostServiceOperations, MessageID) {
        let fixture = try await ServiceOperationsFixture()
        let password = "\(name)-secret"
        let account = serviceAccount(id: "account-\(name)", username: "\(name)@example.com")
        let message = serviceMessage(id: MessageID("msg_\(name)"), threadID: ThreadID("thread-\(name)"), mailboxPath: "INBOX")
        let imap = LocalIMAPServer(
            username: account.username, password: password, message: message,
            peer: LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"],
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")] + serverFolders,
                uidValidity: 9_400, messageUID: 7,
                messageData: Data("Subject: gmail\r\n\r\nbody".utf8)
            )
        )
        try await imap.start()
        try fixture.store.cacheAccounts([replacingIMAPEndpoint(account, port: imap.port)])
        try fixture.store.cacheThread(MailThread(
            id: try XCTUnwrap(message.threadID), accountID: account.id,
            subjectNormalized: name, participantEmails: [message.from]
        ))
        try fixture.store.cacheMailboxes(([LocalIMAPPeerResponse.Mailbox(path: "INBOX", specialUse: "\\Inbox")] + serverFolders).map {
            Mailbox(id: MailboxID("\(name)-\($0.path)"), accountID: account.id, name: $0.path, path: $0.path, specialUse: $0.specialUse)
        })
        _ = try fixture.store.commitIncomingMessage(
            message, metadata: emptySearchMetadata, accountID: account.id,
            mailboxPath: "INBOX", uidValidity: 9_400, uid: 7, notificationEligible: false
        )
        try await storeIMAPPassword(password, accountID: account.id, fixture: fixture)
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()
        return (fixture, imap, operations, message.id)
    }

    func testMacArchiveOnGmailMovesToAllMailKeyedByCOPYUID() async throws {
        let (fixture, imap, operations, messageID) = try await gmailDirectFixture("gmail-mac-archive")
        defer { imap.stop(); fixture.cleanup() }
        let payload = PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: "INBOX")

        let operationResult = try await operations.perform(.archive(payload))

        XCTAssertEqual(imap.uidCommands, [#"MOVE 7 "[Gmail]/All Mail""#])
        guard case .archive(let result) = operationResult else { return XCTFail("expected an archive result") }
        XCTAssertEqual(result.mailboxPath, "[Gmail]/All Mail")
        XCTAssertTrue(operationResult.isSemanticallyCorrelated(with: .archive(payload)),
                      "the app accepts a reply naming the account's own Archive")
        let membership = try fixture.store.actionMembership(for: messageID, shownIn: "[Gmail]/All Mail")
        XCTAssertEqual(membership.uid, 501, "keyed by COPYUID, not the Inbox UID 7")
    }

    func testMacArchiveWithoutAnArchiveFolderRefusesBeforeAnyUIDCommand() async throws {
        let (fixture, imap, operations, messageID) = try await gmailDirectFixture(
            "no-archive-mac", serverFolders: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        defer { imap.stop(); fixture.cleanup() }

        do {
            _ = try await operations.perform(.archive(PlainpostMailActionPayload(messageID: messageID.rawValue)))
            XCTFail("no Archive folder must refuse")
        } catch PlainpostError.validationFailed(let text) {
            XCTAssertEqual(text, ArchiveMailbox.noArchiveMessage)
        }
        XCTAssertEqual(imap.uidCommands, [])
        XCTAssertEqual(try fixture.store.messageSummary(id: messageID)?.mailboxPath, "INBOX")
    }

    func testSmartInboxBatchArchiveOnGmailMovesToAllMail() async throws {
        let (fixture, imap, operations, messageID) = try await gmailDirectFixture("gmail-batch")
        defer { imap.stop(); fixture.cleanup() }
        _ = try fixture.store.markSeen(messageID, seen: true, actor: PlainpostFixtures.codexActor)

        let result = try await operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(
                accountID: "account-gmail-batch", category: "seen", action: "archive_read", archiveMailbox: "Archive"
            )
        )

        XCTAssertEqual(result.affectedMessageIDs, [messageID.rawValue])
        XCTAssertEqual(result.archiveMailbox, "[Gmail]/All Mail")
        XCTAssertEqual(imap.uidCommands, [#"MOVE 7 "[Gmail]/All Mail""#])
        XCTAssertEqual(try fixture.store.actionMembership(for: messageID, shownIn: "[Gmail]/All Mail").uid, 501)
    }

    func testNodeFallbackArchiveOnGmailMovesToAllMail() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-gmail-archive", mailbox: "INBOX", serverMailboxes: Self.gmailServerFolders
        )
        defer { imap.stop(); fixture.cleanup() }

        // A journaled archive from before the fix names the old default.
        try await operations.performDirectMailIntent(.archive, messageID: messageID, archiveMailbox: "Archive")

        XCTAssertEqual(imap.moves, [LocalIMAPCopyAttempt(uid: 75, mailbox: "[Gmail]/All Mail")])
        let membership = try fixture.store.displayedMembership(for: messageID)
        XCTAssertEqual(membership.mailboxPath, "[Gmail]/All Mail")
        XCTAssertEqual(membership.uid, 501, "keyed by COPYUID, not the old Inbox UID")
    }

    func testNodeFallbackArchiveOfACopyAlreadyInAllMailSendsNothingAndKeepsIt() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-already-archived", mailbox: "[Gmail]/All Mail", serverMailboxes: [.init(path: "[Gmail]/Trash", specialUse: "\\Trash")]
        )
        defer { imap.stop(); fixture.cleanup() }

        try await operations.performDirectMailIntent(.archive, messageID: messageID, archiveMailbox: "Archive")

        XCTAssertEqual(imap.uidCommands, [], "no move into the mailbox the copy is already in")
        let membership = try fixture.store.displayedMembership(for: messageID)
        XCTAssertEqual(membership.mailboxPath, "[Gmail]/All Mail")
        XCTAssertEqual(membership.uid, 75, "the All Mail copy stays as it was")
    }

    func testSmartInboxBatchArchivesOnlyInboxCopies() async throws {
        let (fixture, imap, operations, messageID) = try await gmailDirectFixture("gmail-batch-trash")
        defer { imap.stop(); fixture.cleanup() }
        _ = try fixture.store.markSeen(messageID, seen: true, actor: PlainpostFixtures.codexActor)
        // The seen message's only copy is now in Trash: the batch must not undo the delete.
        _ = try fixture.store.recordConfirmedTrashMove(
            membership: try fixture.store.membership(for: messageID), to: "[Gmail]/Trash",
            uidValidity: 9_400, uid: 900, actor: PlainpostFixtures.codexActor
        )

        _ = try await operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(
                accountID: "account-gmail-batch-trash", category: "seen", action: "archive_read", archiveMailbox: "Archive"
            )
        )

        XCTAssertEqual(imap.uidCommands, [])
        XCTAssertEqual(try fixture.store.displayedMembership(for: messageID).mailboxPath, "[Gmail]/Trash")
    }

    func testNodeFallbackDeleteMovesToTrashAndNeverErases() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-move", mailbox: "INBOX", serverMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        defer { imap.stop(); fixture.cleanup() }

        try await operations.performDirectMailIntent(.delete, messageID: messageID, archiveMailbox: nil)

        let held = await operations.heldDirectDeleteOutcomeCount
        XCTAssertEqual(held, 0, "a dispatch nobody waits on (a queued intent) keeps no outcome")
        XCTAssertEqual(imap.moves, [LocalIMAPCopyAttempt(uid: 75, mailbox: "Trash")])
        XCTAssertEqual(imap.expungeCount, 0, "no UID EXPUNGE in the source")
        XCTAssertTrue(imap.deletedUIDs.isEmpty)
        let membership = try fixture.store.displayedMembership(for: messageID)
        XCTAssertEqual(membership.mailboxPath, "Trash")
        XCTAssertEqual(membership.uid, 501, "keyed by COPYUID, not the old Inbox UID")
        XCTAssertEqual(try fixture.store.messageSummary(id: messageID)?.isDeleted, false)
    }

    /// A second Inbox UID of the same message, as a server that delivered it twice holds it.
    private func addDuplicateInboxCopy(
        of messageID: MessageID, uid: Int, uidValidity: Int, fixture: ServiceOperationsFixture
    ) throws {
        let message = try XCTUnwrap(try fixture.store.messageSummary(id: messageID))
        let accountID = try XCTUnwrap(fixture.store.accountID(forMessageID: messageID))
        _ = try fixture.store.commitIncomingMessage(
            message, metadata: emptySearchMetadata, accountID: accountID,
            mailboxPath: "INBOX", uidValidity: uidValidity, uid: uid, notificationEligible: false
        )
    }

    func testNodeFallbackDeleteMovesEveryInboxCopyOfAMessageDeliveredTwice() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-duplicate", mailbox: "INBOX", serverMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        defer { imap.stop(); fixture.cleanup() }
        try addDuplicateInboxCopy(of: messageID, uid: 76, uidValidity: 9_100, fixture: fixture)

        try await operations.performDirectMailIntent(.delete, messageID: messageID, archiveMailbox: nil)

        XCTAssertEqual(imap.moves, [
            LocalIMAPCopyAttempt(uid: 75, mailbox: "Trash"), LocalIMAPCopyAttempt(uid: 76, mailbox: "Trash"),
        ])
        let accountID = try XCTUnwrap(fixture.store.accountID(forMessageID: messageID))
        XCTAssertEqual(try fixture.store.cachedUIDs(accountID: accountID, mailboxPath: "INBOX", uidValidity: 9_100), [])
        XCTAssertEqual(try fixture.store.displayedMembership(for: messageID).mailboxPath, "Trash")
    }

    func testSmartInboxBatchArchiveMovesEveryInboxCopyOfAMessageDeliveredTwice() async throws {
        let (fixture, imap, operations, messageID) = try await gmailDirectFixture("batch-duplicate")
        defer { imap.stop(); fixture.cleanup() }
        _ = try fixture.store.markSeen(messageID, seen: true, actor: PlainpostFixtures.codexActor)
        try addDuplicateInboxCopy(of: messageID, uid: 8, uidValidity: 9_400, fixture: fixture)

        _ = try await operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(
                accountID: "account-batch-duplicate", category: "seen", action: "archive_read", archiveMailbox: "Archive"
            )
        )

        XCTAssertEqual(imap.uidCommands, [#"MOVE 7 "[Gmail]/All Mail""#, #"MOVE 8 "[Gmail]/All Mail""#])
        XCTAssertEqual(
            try fixture.store.cachedUIDs(accountID: AccountID("account-batch-duplicate"), mailboxPath: "INBOX", uidValidity: 9_400),
            []
        )
    }

    func testNodeFallbackDeleteWithoutTrashRefusesBeforeAnyChange() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-no-trash", mailbox: "INBOX", serverMailboxes: []
        )
        defer { imap.stop(); fixture.cleanup() }

        do {
            try await operations.performDirectMailIntent(.delete, messageID: messageID, archiveMailbox: nil)
            XCTFail("no Trash must refuse")
        } catch {}

        XCTAssertTrue(imap.moves.isEmpty)
        XCTAssertTrue(imap.copyAttempts.isEmpty)
        XCTAssertEqual(imap.expungeCount, 0)
        XCTAssertEqual(try fixture.store.messageSummary(id: messageID)?.mailboxPath, "INBOX")
        XCTAssertEqual(try fixture.store.messageSummary(id: messageID)?.isDeleted, false)
    }

    func testNodeFallbackDeleteInTrashLeavesTheMessageAlone() async throws {
        let (fixture, imap, operations, messageID) = try await nodeFallbackDeleteFixture(
            "fallback-in-trash", mailbox: "Trash", serverMailboxes: []
        )
        defer { imap.stop(); fixture.cleanup() }

        try await operations.performDirectMailIntent(.delete, messageID: messageID, archiveMailbox: nil)

        XCTAssertTrue(imap.moves.isEmpty)
        XCTAssertEqual(imap.expungeCount, 0, "the fallback never erases")
        XCTAssertTrue(imap.deletedUIDs.isEmpty)
        XCTAssertEqual(try fixture.store.messageSummary(id: messageID)?.isDeleted, false)
    }

    func testRemoteMailActionRejectsStaleUIDValidityBeforeMutation()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let password = "stale-uid-validity-secret"
        let account = serviceAccount(
            id: "account-stale-generation",
            username: "stale@example.com"
        )
        let message = serviceMessage(
            id: MessageID("msg_rfc_stale_generation"),
            threadID: ThreadID("thread-stale-generation"),
            mailboxPath: "Receipts"
        )
        let imap = LocalIMAPServer(
            username: account.username,
            password: password,
            message: message,
            uidValidity: 501,
            messageUID: 88
        )
        try await imap.start()
        defer { imap.stop() }
        let routedAccount = replacingIMAPEndpoint(account, port: imap.port)
        try fixture.store.cacheAccounts([routedAccount])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: account.id,
                subjectNormalized: "stale generation",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: account.id,
            mailboxPath: "Receipts",
            uidValidity: 500,
            uid: 88,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            password,
            accountID: account.id,
            fixture: fixture
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        await XCTAssertThrowsErrorAsync(
            try await operations.perform(
                .delete(
                    PlainpostMailActionPayload(
                        messageID: message.id.rawValue
                    )
                )
            )
        )

        XCTAssertEqual(imap.selectedMailboxes, ["Receipts"])
        XCTAssertEqual(imap.deletedUIDs, [])
        XCTAssertEqual(imap.expungeCount, 0)
    }

    func testRemoteMailActionRejectsMembershipForDifferentThreadAccount()
        async throws
    {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let canonicalAccount = serviceAccount(
            id: "account-canonical-owner",
            username: "owner@example.com"
        )
        let wrongAccount = serviceAccount(
            id: "account-wrong-owner",
            username: "wrong@example.com"
        )
        let password = "wrong-owner-secret"
        let message = serviceMessage(
            id: MessageID("msg_rfc_wrong_owner"),
            threadID: ThreadID("thread-wrong-owner"),
            mailboxPath: "INBOX"
        )
        let imap = LocalIMAPServer(
            username: wrongAccount.username,
            password: password,
            message: message,
            uidValidity: 77,
            messageUID: 99
        )
        try await imap.start()
        defer { imap.stop() }
        try fixture.store.cacheAccounts([
            canonicalAccount,
            replacingIMAPEndpoint(wrongAccount, port: imap.port),
        ])
        try fixture.store.cacheThread(
            MailThread(
                id: try XCTUnwrap(message.threadID),
                accountID: canonicalAccount.id,
                subjectNormalized: "wrong owner",
                participantEmails: [message.from]
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            message,
            metadata: emptySearchMetadata,
            accountID: wrongAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 77,
            uid: 99,
            notificationEligible: false
        )
        try await storeIMAPPassword(
            password,
            accountID: wrongAccount.id,
            fixture: fixture
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        await XCTAssertThrowsErrorAsync(
            try await operations.perform(
                .archive(
                    PlainpostMailActionPayload(
                        messageID: message.id.rawValue
                    )
                )
            )
        )

        XCTAssertEqual(imap.loginAttempts, [])
        XCTAssertEqual(imap.copyAttempts, [])
        XCTAssertEqual(imap.deletedUIDs, [])
    }

    func testDecodedAccountAddDispatchesThroughRealAccountRuntimeWithoutPasswordEcho()
        async throws
    {
        let imapPassword = "service-account-imap-secret"
        let smtpPassword = "service-account-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: smtpPassword
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()
        let encoded = try PlainpostForegroundOperation.accountAdd(
            PlainpostAccountSetupPayload(
                displayName: "Personal",
                email: "me@example.com",
                imapHost: "127.0.0.1",
                imapPort: imap.port,
                smtpHost: "127.0.0.1",
                smtpPort: smtp.port,
                username: "me@example.com",
                sentMailbox: "Sent",
                imapPassword: imapPassword,
                smtpPassword: smtpPassword
            )
        ).requestDTO()
        let decoded = try PlainpostForegroundOperation(requestDTO: encoded)

        let result = try await operations.perform(decoded)

        guard case .accountAdd(let accountResult) = result else {
            return XCTFail("Expected the account-add result kind.")
        }
        XCTAssertEqual(accountResult.accountID, "acc_me_example_com")
        XCTAssertTrue(accountResult.isIMAPVerified)
        XCTAssertTrue(accountResult.isSMTPVerified)
        XCTAssertEqual(
            fixture.store.accounts.map(\.id),
            [AccountID("acc_me_example_com")]
        )
        let storedIMAP = try await fixture.assembly.vault.load(
            CredentialRecordKey(
                rawValue: "account:acc_me_example_com:imap-password"
            )
        )
        let storedSMTP = try await fixture.assembly.vault.load(
            CredentialRecordKey(
                rawValue: "account:acc_me_example_com:smtp-password"
            )
        )
        XCTAssertEqual(storedIMAP, Data(imapPassword.utf8))
        XCTAssertEqual(storedSMTP, Data(smtpPassword.utf8))
        for snapshot in [
            String(describing: decoded),
            String(reflecting: decoded),
            String(describing: result),
            String(reflecting: result),
        ] {
            XCTAssertFalse(snapshot.contains(imapPassword))
            XCTAssertFalse(snapshot.contains(smtpPassword))
        }
    }

    func testDirectDraftDeliveryDispatchesThroughRealSMTPAndIMAPRuntimes() async throws {
        let imapPassword = "service-delivery-imap-secret"
        let smtpPassword = "service-delivery-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: smtpPassword
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = Account(
            id: AccountID("account-delivery"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            username: "me@example.com",
            sentMailbox: "Sent",
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1",
            smtpPort: smtp.port
        )
        try fixture.store.cacheAccounts([account])
        try await fixture.assembly.vault.store(
            Data(imapPassword.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):imap-password"
            )
        )
        try await fixture.assembly.vault.store(
            Data(smtpPassword.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):smtp-password"
            )
        )
        let actor = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )
        let draft = try fixture.store.createDraft(
            Draft(
                id: DraftID("draft-service-delivery"),
                accountID: account.id,
                from: account.email,
                to: [EmailAddress("alice@example.com")],
                cc: [],
                bcc: [],
                subject: "Dispatcher delivery",
                bodyPlain: "This is sent through the real service runtime.",
                createdBy: actor.id,
                aiGenerated: false,
                sourceThreadID: nil
            ),
            actor: actor
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let result = try await operations.perform(
            .deliverDirectDraft(
                PlainpostDirectDraftDeliveryPayload(
                    draftID: draft.id.rawValue,
                    expectedHash: draft.contentHash,
                    actorID: actor.id
                )
            )
        )

        guard case .deliverDirectDraft(let delivery) = result else {
            return XCTFail("Expected the direct-delivery result kind.")
        }
        let acceptedMessages = await smtp.acceptedMessages()
        XCTAssertTrue(delivery.remoteSentCopyAppended)
        XCTAssertEqual(acceptedMessages.count, 1)
        XCTAssertEqual(imap.appendedMessages.count, 1)
        XCTAssertEqual(
            try fixture.store.directSendIntent(draftID: draft.id, contentHash: draft.contentHash)?.state,
            .sent
        )
        XCTAssertNotNil(
            try fixture.store.messageSummary(
                id: MessageID(delivery.messageID)
            )
        )
    }

    func testLabelCommandDispatchesThroughRealLabelStoreMutation() async throws {
        let fixture = try await ServiceOperationsFixture()
        defer { fixture.cleanup() }
        let account = PlainpostFixtures.personalAccount
        try fixture.store.cacheAccounts([account])
        try fixture.store.saveMailLabel(
            try MailLabelDefinition.validated(
                id: "travel",
                title: "Travel",
                description: "",
                isSmartInboxEnabled: false,
                scope: .allAccounts
            )
        )
        _ = try fixture.store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let operations = fixture.makeOperations()
        await operations.reopenRuntimeConstruction()

        let result = try await operations.perform(
            .labelCommand(
                PlainpostLabelMutationPayload(
                    labelID: "travel",
                    messageID: PlainpostFixtures.aliceMessage.id.rawValue,
                    selected: true
                )
            )
        )

        XCTAssertEqual(result.kind, .labelCommand)
        XCTAssertEqual(
            try fixture.store.messageSummary(
                id: PlainpostFixtures.aliceMessage.id
            )?.labels,
            ["Travel"]
        )
    }

    private func makeInjectedComposition(
        databaseURL: URL,
        assembly: SQLiteCredentialVaultAssembly,
        directNotificationAssemblyFactory: (SQLiteMailStore) ->
            PlainpostServiceComposition.DirectNotificationAssembly
    ) throws -> PlainpostServiceComposition {
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let directNotificationAssembly = directNotificationAssemblyFactory(store)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: databaseURL.deletingLastPathComponent(),
            store: store,
            assembly: assembly,
            notificationDrain: directNotificationAssembly.notificationDrain,
            installNotificationConfiguration: directNotificationAssembly.install
        )
        let lifecycle = PlainpostServiceLifecycleCoordinator(
            vaultSession: assembly.session,
            prepareForegroundUnlock: {
                try await assembly.prepareForegroundUnlock()
            },
            beginVaultLockdown: {
                await operations.beginVaultLockdown()
            },
            confirmVaultLocked: {
                await operations.confirmVaultLocked()
            },
            recoverAfterUnlock: {
                try await assembly.recoverPendingAccountDeletions()
            },
            reopenRuntimeConstruction: {
                await operations.reopenRuntimeConstruction()
            }
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: lifecycle,
            performForegroundOperation: { operation in
                try await operations.perform(operation)
            },
            processBackgroundJobs: {
                try await operations.processBackgroundJobs()
            },
            performSmartInboxBatch: { request in
                try await operations.performSmartInboxBatch(request)
            },
            sendBrowserApprovedReply: { jobID in
                try await operations.sendBrowserApprovedReply(jobID: jobID)
            },
            syncDraftToServer: { draftID, mailbox in
                try await operations.syncDraftToServer(
                    draftID: draftID,
                    mailbox: mailbox
                )
            }
        )
        return PlainpostServiceComposition(
            listener: listener,
            lifecycle: lifecycle,
            operations: operations,
            store: store
        )
    }

}

private actor ServiceOriginRecordingTransport: AccountHTTPTransport {
    private(set) var lastURL: URL?
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        lastURL = request.url
        throw AccountRuntimeError.transportFailure
    }
}

private actor AssignmentSequence {
    private var values: [[NotificationProducerAssignment]]

    init(values: [[NotificationProducerAssignment]]) {
        self.values = values
    }

    func next() -> [NotificationProducerAssignment] {
        guard values.count > 1 else { return values.first ?? [] }
        return values.removeFirst()
    }
}

private actor DirectReconciliationRaceSource {
    private let assignment: NotificationProducerAssignment
    private let logicalMailboxID: LogicalMailboxID
    private var assignmentCalls = 0
    private var snapshotCalls = 0
    private var oldObservationEntered: CheckedContinuation<Void, Never>?
    private var oldObservationRelease: CheckedContinuation<[NotificationProducerAssignment], Never>?

    init(assignment: NotificationProducerAssignment, logicalMailboxID: LogicalMailboxID) {
        self.assignment = assignment
        self.logicalMailboxID = logicalMailboxID
    }

    func assignments() async -> [NotificationProducerAssignment] {
        assignmentCalls += 1
        switch assignmentCalls {
        case 1:
            return []
        case 2:
            oldObservationEntered?.resume()
            oldObservationEntered = nil
            return await withCheckedContinuation { (continuation: CheckedContinuation<[NotificationProducerAssignment], Never>) in
                oldObservationRelease = continuation
            }
        default:
            return [assignment]
        }
    }

    func snapshot() -> DirectNotificationPolicySnapshot {
        snapshotCalls += 1
        let isNewer = snapshotCalls > 1
        let state = try! DirectNotificationPolicyMailboxState(
            logicalMailboxID: logicalMailboxID,
            mode: .senderSubject,
            version: "1",
            scopeVersion: "1",
            override: true
        )
        return DirectNotificationPolicySnapshot(
            defaultPolicy: try! DirectNotificationPolicyState(
                logicalMailboxID: nil, mode: .richPreview, version: "1",
                scopeVersion: "0", override: false
            ),
            mailboxPolicies: [],
            mailboxStates: isNewer ? [state] : []
        )
    }

    func waitUntilOldObservationBlocks() async {
        if assignmentCalls >= 2 { return }
        await withCheckedContinuation { continuation in
            oldObservationEntered = continuation
        }
    }

    func releaseOldObservation() {
        oldObservationRelease?.resume(returning: [])
        oldObservationRelease = nil
    }
}

private let emptySearchMetadata = IncomingMessageSearchMetadata(
    to: [],
    cc: [],
    bcc: [],
    attachments: [],
    messageIdentifiers: []
)

private func serviceAccount(id: String, username: String) -> Account {
    Account(
        id: AccountID(id),
        displayName: username,
        email: EmailAddress(username),
        username: username,
        sentMailbox: "Sent",
        imapHost: "127.0.0.1",
        imapPort: 1,
        smtpHost: "127.0.0.1",
        smtpPort: 1
    )
}

private func replacingIMAPEndpoint(
    _ account: Account,
    port: UInt16
) -> Account {
    Account(
        id: account.id,
        displayName: account.displayName,
        email: account.email,
        username: account.username,
        sentMailbox: account.sentMailbox,
        imapHost: "127.0.0.1",
        imapPort: port,
        smtpHost: account.smtpHost,
        smtpPort: account.smtpPort
    )
}

private func serviceMessage(
    id: MessageID,
    threadID: ThreadID,
    mailboxPath: String
) -> MessageSummary {
    MessageSummary(
        id: id,
        threadID: threadID,
        from: EmailAddress("sender@example.com"),
        fromDisplayName: "Sender",
        subject: "Canonical remote action",
        preview: "Canonical remote action body",
        smartCategory: .personal,
        labels: [],
        isSeen: false,
        mailboxPath: mailboxPath,
        isDeleted: false,
        body: "Canonical remote action body",
        sentAt: Date(timeIntervalSince1970: 1_720_000_000),
        to: [EmailAddress("recipient@example.com")]
    )
}

private func storeIMAPPassword(
    _ password: String,
    accountID: AccountID,
    fixture: ServiceOperationsFixture
) async throws {
    try await fixture.assembly.vault.store(
        Data(password.utf8),
        for: CredentialRecordKey(
            rawValue: "account:\(accountID.rawValue):imap-password"
        )
    )
}

private func enqueueFailingMailboxFlagJob(
    fixture: ServiceOperationsFixture,
    suffix: String
) async throws -> PlainpostDurableJob {
    let account = serviceAccount(
        id: "account-retry-\(suffix)",
        username: "retry-\(suffix)@example.com"
    )
    let unreachableAccount = Account(
        id: account.id,
        displayName: account.displayName,
        email: account.email,
        username: account.username,
        sentMailbox: account.sentMailbox,
        imapHost: "127.0.0.1",
        imapPort: 1,
        smtpHost: account.smtpHost,
        smtpPort: account.smtpPort
    )
    let message = serviceMessage(
        id: MessageID("message-retry-\(suffix)"),
        threadID: ThreadID("thread-retry-\(suffix)"),
        mailboxPath: "INBOX"
    )
    try fixture.store.cacheAccounts([unreachableAccount])
    try fixture.store.cacheThread(
        MailThread(
            id: try XCTUnwrap(message.threadID),
            accountID: account.id,
            subjectNormalized: "retry \(suffix)",
            participantEmails: [message.from]
        )
    )
    _ = try fixture.store.commitIncomingMessage(
        message,
        metadata: emptySearchMetadata,
        accountID: account.id,
        mailboxPath: "INBOX",
        uidValidity: 1,
        uid: 92,
        notificationEligible: false
    )
    try await storeIMAPPassword(
        "retry-\(suffix)-secret",
        accountID: account.id,
        fixture: fixture
    )
    let input = PlainpostMailboxFlagInput(
        messageID: message.id,
        accountID: account.id,
        mailboxPath: "INBOX",
        uidValidity: 1,
        uid: 92,
        desiredSeen: true
    )
    return try fixture.store.enqueueJob(
        PlainpostJobRequest(
            kind: .mailboxFlag,
            payloadJSON: String(
                decoding: try JSONEncoder().encode(input),
                as: UTF8.self
            ),
            priority: 100,
            maxAttempts: 3,
            idempotencyKey: "agent-retry-\(suffix)"
        )
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected operation to throw.", file: file, line: line)
    } catch {}
}

private final class RecordingMailboxFlagScheduler: MailboxFlagScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var scheduleCalls = 0
    private var signalCalls = 0

    func schedule(_ input: PlainpostMailboxFlagInput) throws {
        lock.withLock { scheduleCalls += 1 }
    }

    func signalWork() async throws {
        lock.withLock { signalCalls += 1 }
    }

    func snapshot() -> (schedule: Int, signal: Int) {
        lock.withLock { (scheduleCalls, signalCalls) }
    }
}

private actor FixedVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x47, count: 32)

    func createIfMissing() async throws {}

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        key
    }

    func countMatchingItems() async throws -> Int {
        1
    }
}

private actor ProductionDirectPolicySequence {
    private var defaultVersion = "1"
    private var mode: NodeSyncNotificationPolicyMode = .richPreview
    private var version: Int64 = 1
    private var scope: Int64 = 0
    private var override = false

    func set(
        defaultVersion: String,
        mode: NodeSyncNotificationPolicyMode,
        version: Int64,
        scope: Int64,
        override: Bool
    ) {
        self.defaultVersion = defaultVersion
        self.mode = mode
        self.version = version
        self.scope = scope
        self.override = override
    }

    func snapshot() throws -> DirectNotificationPolicySnapshot {
        let logical = LogicalMailboxID(rawValue: Data(repeating: 0x6A, count: 32))!
        return DirectNotificationPolicySnapshot(
            defaultPolicy: try DirectNotificationPolicyState(
                logicalMailboxID: nil,
                mode: override ? .richPreview : mode,
                version: defaultVersion,
                scopeVersion: "0",
                override: false
            ),
            mailboxPolicies: [],
            mailboxStates: [try DirectNotificationPolicyMailboxState(
                logicalMailboxID: logical,
                mode: mode,
                version: String(version),
                scopeVersion: String(scope),
                override: override
            )]
        )
    }
}

private struct ProductionCoordinationClient: CoordinationClient {
    let recipientID: AccountDeviceID
    let recipientAgreementPublicKey: Data

    init(recipientID: AccountDeviceID, recipientAgreementPublicKey: Data) {
        self.recipientID = recipientID
        self.recipientAgreementPublicKey = recipientAgreementPublicKey
    }

    func recipientAssignment(
        for _: NotificationPublicationSource,
        claim: NotificationPublicationClaim
    ) async throws -> NotificationRecipientAssignment {
        let recipient = NotificationRecipientSnapshot(
            recipientID: recipientID.rawValue,
            routingHandle: Data(repeating: 1, count: 32),
            agreementPublicKey: recipientAgreementPublicKey
        )
        return NotificationRecipientAssignment(
            recipients: [recipient], signedBytes: Data(), signature: Data(),
            signerDeviceID: claim.producerDeviceID ?? "",
            configVersion: claim.configVersion,
            producerGeneration: claim.producerGeneration,
            policyVersion: claim.policyVersion
        )
    }
}

private struct ProductionAssignmentVerifier: RecipientAssignmentVerifying {
    func verify(
        assignment _: NotificationRecipientAssignment,
        source _: NotificationPublicationSource
    ) throws {}
}

private actor ProductionRecordingRelay: RelayClient {
    private var envelopes: [Data] = []

    func deliver(_ delivery: NotificationDeliveryClaim) async throws -> NotificationRelayResult {
        envelopes.append(delivery.envelopeBytes)
        return NotificationRelayResult(outcome: .accepted)
    }

    func lastEnvelope() -> Data? { envelopes.last }
    func count() -> Int { envelopes.count }
}

private final class ServiceOperationsFixture: @unchecked Sendable {
    let applicationSupportURL: URL
    let store: SQLiteMailStore
    let assembly: SQLiteCredentialVaultAssembly

    init() async throws {
        applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plainpost-service-operations-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        let databaseURL = applicationSupportURL.appendingPathComponent("plainpost.sqlite")
        store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        assembly = SQLiteCredentialVaultAssembly(
            store: store,
            provider: FixedVaultKeyProvider()
        )
        try await assembly.unlockForeground(prompt: "Test-only in-memory vault unlock")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    func makeOperations(
        mailboxFlagScheduler: (any MailboxFlagScheduling)? = nil,
        backgroundJobWakeScheduler:
            (any BackgroundJobWakeScheduling)? = nil,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        accountRuntimeFactory: (@Sendable () -> AccountSetupService)? = nil,
        operationRuntimeFactory: (@Sendable () -> LocalOperationRuntime)? = nil,
        mailMonitorFactory: @escaping @Sendable (
            @escaping IMAPIdleSupervisor.Signal
        ) -> any ServiceMailMonitoring = { _ in NoopServiceMailMonitor() }
    ) -> PlainpostServiceOperations {
        PlainpostServiceOperations(
            applicationSupportURL: applicationSupportURL,
            store: store,
            assembly: assembly,
            mailboxFlagScheduler: mailboxFlagScheduler,
            backgroundJobWakeScheduler: backgroundJobWakeScheduler,
            dateProvider: dateProvider,
            accountRuntimeFactory: accountRuntimeFactory,
            operationRuntimeFactory: operationRuntimeFactory,
            mailMonitorFactory: mailMonitorFactory
        )
    }
}

private actor NoopServiceMailMonitor: ServiceMailMonitoring {
    func start() {}
    func stop() {}
}

private final class RecordingMailMonitorFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let blockStops: Bool
    private var monitors: [RecordingServiceMailMonitor] = []

    init(blockStops: Bool = false) {
        self.blockStops = blockStops
    }

    var count: Int { lock.withLock { monitors.count } }

    func make(
        signal: @escaping IMAPIdleSupervisor.Signal
    ) -> any ServiceMailMonitoring {
        let monitor = RecordingServiceMailMonitor(
            signal: signal,
            blockStop: blockStops
        )
        lock.withLock { monitors.append(monitor) }
        return monitor
    }

    func monitor(at index: Int) -> RecordingServiceMailMonitor? {
        lock.withLock {
            monitors.indices.contains(index) ? monitors[index] : nil
        }
    }
}

private actor RecordingServiceMailMonitor: ServiceMailMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let signal: IMAPIdleSupervisor.Signal
    private let blockStop: Bool
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(
        signal: @escaping IMAPIdleSupervisor.Signal,
        blockStop: Bool
    ) {
        self.signal = signal
        self.blockStop = blockStop
    }

    func start() {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
        guard blockStop else { return }
        await withCheckedContinuation { stopContinuation = $0 }
    }

    func emit(_ accountID: AccountID) async throws {
        try await signal(accountID)
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor ServiceCompletionRecorder {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private func waitForServiceCondition(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for service condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor AccountDeletionCompletionProbe {
    private var completedResult: PlainpostForegroundOperationResult?
    private var completedError: Error?

    var isCompleted: Bool {
        completedResult != nil || completedError != nil
    }

    func finish(result: PlainpostForegroundOperationResult) {
        completedResult = result
    }

    func finish(error: Error) {
        completedError = error
    }

    func result() throws -> PlainpostForegroundOperationResult {
        if let completedError { throw completedError }
        return try XCTUnwrap(completedResult)
    }
}

private final class DeletionHoldingClassificationProvider: AIProvider, @unchecked Sendable {
    let id = "deletion-holding"
    let displayName = "Deletion Holding"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: true,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let controller = DeletionHoldingClassificationController()

    func waitUntilClassificationStarts() async {
        await controller.waitUntilClassificationStarts()
    }

    func cancellationStarted() async -> Bool {
        await controller.cancellationStarted
    }

    func releaseClassification() async {
        await controller.release()
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        .init(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }

    func classifyBatch(
        _ request: AIClassificationBatchRequest
    ) async throws -> AIClassificationBatchResponse {
        try await controller.classify(request)
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        throw AIProviderError.unavailable
    }
}

private actor DeletionHoldingClassificationController {
    private var started = false
    private(set) var cancellationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var attempt = 0

    func waitUntilClassificationStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func classify(
        _ request: AIClassificationBatchRequest
    ) async throws -> AIClassificationBatchResponse {
        attempt += 1
        if attempt > 1 {
            return AIClassificationBatchResponse(results: request.messages.map {
                AIClassificationCandidate(
                    id: $0.id.rawValue,
                    category: SmartCategory.newsletter.rawValue,
                    priority: SmartPriority.normal.rawValue,
                    requiresAction: false,
                    confidence: 0.9
                )
            })
        }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseContinuation = $0 }
        } onCancel: {
            Task { await self.markCancellationStarted() }
        }
        try Task.checkCancellation()
        throw CancellationError()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func markCancellationStarted() {
        cancellationStarted = true
    }
}

private final class TransportFactoryCallProbe: @unchecked Sendable {
    struct Snapshot: Equatable {
        let imap: Int
        let smtp: Int
    }

    private let lock = NSLock()
    private var imapCalls = 0
    private var smtpCalls = 0

    func recordIMAP() {
        lock.withLock { imapCalls += 1 }
    }

    func recordSMTP() {
        lock.withLock { smtpCalls += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(imap: imapCalls, smtp: smtpCalls) }
    }
}

private actor BlockingAccountTestGate {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func block() async {
        started = true
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct BlockingAccountTestIMAPClient: IMAPClientProtocol {
    let gate: BlockingAccountTestGate

    func login(username: String, password: String) async throws {
        await gate.block()
        throw IMAPClientError.connectionFailed
    }

    func listMailboxes() async throws -> [Mailbox] { throw IMAPClientError.connectionFailed }
    func selectMailbox(_ path: String) async throws -> String { throw IMAPClientError.connectionFailed }
    func allMessageUIDs() async throws -> [Int] { throw IMAPClientError.connectionFailed }
    func fetchHeader(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func fetchBody(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func markRead(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func markUnread(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func archive(uid: Int, archiveMailbox: String) async throws {
        throw IMAPClientError.connectionFailed
    }
    func delete(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws
        -> IMAPAppendResult
    {
        throw IMAPClientError.connectionFailed
    }
}

private actor RecordingBackgroundJobWakeScheduler:
    BackgroundJobWakeScheduling
{
    private(set) var scheduledAt: Date?
    private var action: (@Sendable () async -> Void)?
    private(set) var fireCount = 0

    func replaceWake(
        at date: Date?,
        action: @escaping @Sendable () async -> Void
    ) {
        scheduledAt = date
        self.action = date == nil ? nil : action
    }

    func fire() async {
        let current = action
        action = nil
        scheduledAt = nil
        guard current != nil else { return }
        fireCount += 1
        await current?()
    }
}

private actor ReentrantBeforeReturnBackgroundJobWakeScheduler:
    BackgroundJobWakeScheduling
{
    private(set) var futureReplacementCount = 0
    private(set) var reentrantActionCount = 0
    private var didBlockFutureReplacement = false
    private var futureReplacementIsBlocked = false
    private var blockedAction: (@Sendable () async -> Void)?
    private var replacementRelease:
        CheckedContinuation<Void, Never>?
    private var reentrantActionStarted = false
    private var reentrantActionCompleted = false

    func replaceWake(
        at date: Date?,
        action: @escaping @Sendable () async -> Void
    ) async {
        guard date != nil else { return }
        futureReplacementCount += 1
        guard !didBlockFutureReplacement else { return }
        didBlockFutureReplacement = true
        futureReplacementIsBlocked = true
        blockedAction = action
        await withCheckedContinuation {
            replacementRelease = $0
        }
        futureReplacementIsBlocked = false
        blockedAction = nil
    }

    func waitUntilFutureReplacementIsBlocked() async -> Bool {
        await waitUntil { futureReplacementIsBlocked }
    }

    func fireWhileReplacementIsBlocked() {
        guard let blockedAction else { return }
        reentrantActionCount += 1
        Task {
            reentrantActionStarted = true
            await blockedAction()
            reentrantActionCompleted = true
        }
    }

    func waitUntilReentrantActionStarted() async -> Bool {
        await waitUntil { reentrantActionStarted }
    }

    func waitUntilReentrantActionCompleted() async -> Bool {
        await waitUntil { reentrantActionCompleted }
    }

    func releaseFutureReplacement() {
        let continuation = replacementRelease
        replacementRelease = nil
        continuation?.resume()
    }

    private func waitUntil(
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private final class MutableTestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func set(_ date: Date) {
        lock.withLock { self.date = date }
    }
}

private final class SequencedTestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        precondition(!dates.isEmpty)
        self.dates = dates
    }

    func now() -> Date {
        lock.withLock {
            if dates.count > 1 {
                return dates.removeFirst()
            }
            return dates[0]
        }
    }
}

private final class BlockingIMAPSessionStartGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false

    func block() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 2)
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<500 {
            if lock.withLock({ started }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func open() {
        release.signal()
    }
}

private actor BackgroundDrainCallProbe {
    private(set) var result: PlainpostBackgroundJobResult?
    private(set) var errorDescription: String?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    var isCompleted: Bool {
        result != nil || errorDescription != nil
    }

    func markStarted() {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startedWaiters.append($0)
        }
    }

    func record(_ result: PlainpostBackgroundJobResult) {
        self.result = result
    }

    func record(_ error: Error) {
        errorDescription = String(describing: error)
    }
}
