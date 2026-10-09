import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class CentralServerConfigurationTests: XCTestCase {
    private let legacy = Data(#"{"kind":"plainpost.central-server-config.v1","origin":"https://plainpost-api.olhapi.com"}"#.utf8)

    func testDecodeAcceptsOnlyCanonicalHTTPSRootOrigins() throws {
        let cases: [(String, CentralServerConfiguration.ValidationError)] = [
            (#"{"kind":"plainpost.central-server-config.v1","origin":"http://central.example"}"#, .httpsRequired),
            (#"{"kind":"plainpost.central-server-config.v1","origin":"https:///"}"#, .hostRequired),
            (#"{"kind":"plainpost.central-server-config.v1","origin":"https://central.example/api"}"#, .rootOriginRequired),
            (#"{"kind":"plainpost.central-server-config.v1","origin":"https://user@central.example"}"#, .forbiddenURLComponents),
            (#"{"kind":"plainpost.central-server-config.v1","origin":"https://central.example?q=1"}"#, .forbiddenURLComponents),
            (#"{"kind":"plainpost.central-server-config.v1","origin":"https://CENTRAL.example/"}"#, .malformedConfiguration),
        ]

        for (wire, expected) in cases {
            XCTAssertThrowsError(try CentralServerConfiguration.decode(Data(wire.utf8)), wire) { error in
                XCTAssertEqual(error as? CentralServerConfiguration.ValidationError, expected)
            }
        }

        let value = try CentralServerConfiguration(originText: "https://central.example:8443")
        XCTAssertEqual(value.origin.absoluteString, "https://central.example:8443")
        XCTAssertEqual(value.canonicalDocument, Data(#"{"kind":"plainpost.central-server-config.v1","origin":"https://central.example:8443"}"#.utf8))
    }

    func testDecodeRejectsMalformedOversizedDuplicateAndUnknownDocuments() {
        let documents = [
            Data(),
            Data(repeating: 0x20, count: 4097),
            Data(#"{"kind":"plainpost.central-server-config.v1","kind":"plainpost.central-server-config.v1","origin":"https://central.example"}"#.utf8),
            Data(#"{"extra":"x","kind":"plainpost.central-server-config.v1","origin":"https://central.example"}"#.utf8),
            Data(#"{"kind":"wrong","origin":"https://central.example"}"#.utf8),
            Data([0xff]),
        ]
        for document in documents {
            XCTAssertThrowsError(try CentralServerConfiguration.decode(document))
        }
    }

    func testBundledConfigurationLoadsAsCanonicalLegacyOrigin() throws {
        let document = try XCTUnwrap(CentralServerConfiguration.bundledDocument)
        let configuration = try CentralServerConfiguration.decode(document)
        XCTAssertEqual(configuration.origin, CentralServerConfiguration.legacyProductionOrigin)
        XCTAssertEqual(document, configuration.canonicalDocument)
    }

    func testResolverUsesOverrideBeforeBundleAndBindsFreshSelection() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.central.credentials")
        let override = try CentralServerConfiguration(originText: "https://override.example")
        XCTAssertTrue(try store.installSelectionIfAbsent(override.canonicalSelectionRecord))

        let resolution = CentralServerConfigurationResolver(store: store).resolve(
            bundledDocument: legacy,
            credentials: credentials
        )

        XCTAssertEqual(resolution, .configured(override))
        XCTAssertEqual(try store.loadSelection(), override.canonicalSelectionRecord)
    }

    func testResolverRequiresSetupWithoutAnySourceOrAccountState() {
        let secrets = InMemoryAccountSecretStore()
        let resolution = CentralServerConfigurationResolver(
            store: KeychainCentralServerConfigurationStore(secretStore: secrets)
        ).resolve(
            bundledDocument: nil,
            credentials: AccountCredentialStore(secretStore: secrets, service: "test.central.empty")
        )
        XCTAssertEqual(resolution, .setupRequired)
    }

    func testPresentInvalidOverrideFailsClosedInsteadOfUsingValidBundle() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        XCTAssertTrue(try store.installSelectionIfAbsent(Data(#"{"boundOrigin":"http://bad.example","configuration":{"kind":"plainpost.central-server-config.v1","origin":"http://bad.example"},"kind":"plainpost.central-server-selection.v1"}"#.utf8)))

        let resolution = CentralServerConfigurationResolver(store: store).resolve(
            bundledDocument: legacy,
            credentials: AccountCredentialStore(secretStore: secrets, service: "test.central.invalid")
        )

        guard case .repairRequired(let repair) = resolution else { return XCTFail("expected repair") }
        XCTAssertEqual(repair.reason, .invalidSelection)
    }

    func testBoundAccountRejectsSelectionWhoseOriginWasChangedExternally() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let tampered = Data(#"{"boundOrigin":"https://plainpost-api.olhapi.com","configuration":{"kind":"plainpost.central-server-config.v1","origin":"https://other.example"},"kind":"plainpost.central-server-selection.v1"}"#.utf8)
        XCTAssertTrue(try store.installSelectionIfAbsent(tampered))
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.central.bound")
        try credentials.saveSession(AccountSession(credentials: try sessionCredentials()))

        let resolution = CentralServerConfigurationResolver(store: store).resolve(
            bundledDocument: legacy,
            credentials: credentials
        )

        guard case .repairRequired(let repair) = resolution else { return XCTFail("expected repair") }
        XCTAssertEqual(repair.reason, .originMismatch)
        XCTAssertEqual(repair.boundOrigin?.absoluteString, "https://plainpost-api.olhapi.com")

        let repaired = CentralServerConfigurationResolver(store: store).saveManualOrigin(
            "https://plainpost-api.olhapi.com",
            bundledDocument: legacy,
            credentials: credentials
        )
        XCTAssertEqual(repaired, .configured(try CentralServerConfiguration.decode(legacy)))
    }

    func testLegacyUnboundAccountMigratesOnlyExactLegacyOrigin() throws {
        let legacySecrets = InMemoryAccountSecretStore()
        let legacyStore = KeychainCentralServerConfigurationStore(secretStore: legacySecrets)
        let legacyCredentials = AccountCredentialStore(secretStore: legacySecrets, service: "test.central.legacy")
        try legacyCredentials.saveSession(AccountSession(credentials: try sessionCredentials()))
        XCTAssertEqual(
            CentralServerConfigurationResolver(store: legacyStore).resolve(bundledDocument: legacy, credentials: legacyCredentials),
            .configured(try CentralServerConfiguration.decode(legacy))
        )
        XCTAssertEqual(try legacyStore.loadSelection(), try CentralServerConfiguration.decode(legacy).canonicalSelectionRecord)

        let customSecrets = InMemoryAccountSecretStore()
        let customCredentials = AccountCredentialStore(secretStore: customSecrets, service: "test.central.custom")
        try customCredentials.saveSession(AccountSession(credentials: try sessionCredentials()))
        let custom = try CentralServerConfiguration(originText: "https://custom.example")
        let blocked = CentralServerConfigurationResolver(
            store: KeychainCentralServerConfigurationStore(secretStore: customSecrets)
        ).resolve(bundledDocument: custom.canonicalDocument, credentials: customCredentials)
        guard case .repairRequired(let repair) = blocked else { return XCTFail("expected repair") }
        XCTAssertEqual(repair.reason, .legacyAccountRequiresKnownOrigin)
    }

    func testLegacyMigrationLosingCASRejectsWinnerOnAnotherOrigin() throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.central.race")
        try credentials.saveSession(AccountSession(credentials: try sessionCredentials()))
        let winner = try CentralServerConfiguration(originText: "https://attacker.example")
        let store = LosingInstallStore(winner: winner.canonicalSelectionRecord)

        let resolution = CentralServerConfigurationResolver(store: store).resolve(
            bundledDocument: legacy,
            credentials: credentials
        )

        guard case .repairRequired(let repair) = resolution else { return XCTFail("expected repair") }
        XCTAssertEqual(repair.reason, .originMismatch)
        XCTAssertEqual(repair.boundOrigin, CentralServerConfiguration.legacyProductionOrigin)
    }

    func testManualSaveCanCorrectPristineBindingButCannotRebindAnAccount() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.central.correct")
        let first = try CentralServerConfiguration(originText: "https://typo.example")
        XCTAssertTrue(try store.installSelectionIfAbsent(first.canonicalSelectionRecord))

        let resolver = CentralServerConfigurationResolver(store: store)
        let corrected = resolver.saveManualOrigin("https://correct.example", bundledDocument: nil, credentials: credentials)
        XCTAssertEqual(corrected, .configured(try CentralServerConfiguration(originText: "https://correct.example")))

        try credentials.saveSession(AccountSession(credentials: try sessionCredentials()))
        let rejected = resolver.saveManualOrigin("https://third.example", bundledDocument: nil, credentials: credentials)
        guard case .repairRequired(let repair) = rejected else { return XCTFail("expected repair") }
        XCTAssertEqual(repair.reason, .originMismatch)
    }

    func testPristineReplacementFencesCompetingFirstAccountCommit() async throws {
        let secrets = InMemoryAccountSecretStore()
        let original = try CentralServerConfiguration(originText: "https://typo.example")
        let replacement = try CentralServerConfiguration(originText: "https://correct.example")
        let store = BlockingReplaceStore(initial: original.canonicalSelectionRecord)
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.central.fenced")
        let session = AccountSession(credentials: try sessionCredentials())
        let resolver = CentralServerConfigurationResolver(store: store)

        let replacementTask = Task.detached {
            resolver.replacePristineOrigin(
                replacement,
                expectedSelection: original.canonicalSelectionRecord,
                bundledDocument: nil,
                credentials: credentials
            )
        }
        await store.waitUntilCASStarted()
        let commitRecorder = CommitRecorder()
        let commitTask = Task.detached {
            await commitRecorder.markStarted()
            try credentials.saveSession(session)
            await commitRecorder.markCompleted()
        }
        await commitRecorder.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(30))
        let completedInsideFence = await commitRecorder.completed
        XCTAssertFalse(completedInsideFence, "competing commit must remain outside the fence")
        await store.finishCAS()

        let resolution = await replacementTask.value
        XCTAssertEqual(resolution, .configured(replacement))
        try await commitTask.value
        XCTAssertEqual(try credentials.loadSession(), session)
        XCTAssertEqual(try store.loadSelection(), replacement.canonicalSelectionRecord)
    }

    private func sessionCredentials() throws -> AccountSessionCredentials {
        try AccountSessionCredentials(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshCredential: Data(repeating: 7, count: 32),
            offlineLease: "lease"
        )
    }

    func testConfigurationExposesNoAudience() throws {
        let configuration = try CentralServerConfiguration(originText: "https://central.example")
        let labels = Mirror(reflecting: configuration).children.compactMap(\.label)
        XCTAssertEqual(labels, ["origin"], "a Central origin must never be reusable as a Sync Node audience")
    }
}

private final class BlockingReplaceStore: CentralServerConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var selection: Data
    private var casStarted = false
    private let casRelease = DispatchSemaphore(value: 0)

    init(initial: Data) { selection = initial }
    func loadSelection() throws -> Data? { lock.lock(); defer { lock.unlock() }; return selection }
    func installSelectionIfAbsent(_: Data) throws -> Bool { false }
    func replacePristineSelection(expected: Data, replacement: Data) throws -> Bool {
        lock.lock()
        guard selection == expected else { lock.unlock(); return false }
        casStarted = true
        lock.unlock()
        casRelease.wait()
        lock.lock(); defer { lock.unlock() }
        guard selection == expected else { return false }
        selection = replacement
        return true
    }
    func waitUntilCASStarted() async {
        while !didStartCAS() { await Task.yield() }
    }
    func finishCAS() async { casRelease.signal() }
    private func didStartCAS() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return casStarted
    }
}

private actor CommitRecorder {
    private var started = false
    private(set) var completed = false
    func markStarted() { started = true }
    func markCompleted() { completed = true }
    func waitUntilStarted() async { while !started { await Task.yield() } }
}

private final class LosingInstallStore: CentralServerConfigurationStoring, @unchecked Sendable {
    private let winner: Data
    private let lock = NSLock()
    private var loads = 0
    init(winner: Data) { self.winner = winner }
    func loadSelection() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return loads == 1 ? nil : winner
    }
    func installSelectionIfAbsent(_ canonicalRecord: Data) throws -> Bool { false }
    func replacePristineSelection(expected: Data, replacement: Data) throws -> Bool { false }
}
