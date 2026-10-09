import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostUI
@testable import PlainpostApp

@MainActor
final class PlainpostAccountLaunchModelTests: XCTestCase {
    func testNoConfigurationShowsSetupWithoutConstructingAccountModel() {
        let fixture = Fixture(bundled: nil)
        XCTAssertTrue(fixture.model.showsSetup)
        XCTAssertNil(fixture.model.accountModel)
        XCTAssertEqual(fixture.factoryCalls, 0)
    }

    func testBundledConfigurationBindsThenConstructsExactlyOnce() throws {
        let bundled = try CentralServerConfiguration(originText: "https://central.example")
        let fixture = Fixture(bundled: bundled.canonicalDocument)
        XCTAssertEqual(fixture.model.selectedServer, bundled)
        XCTAssertNotNil(fixture.model.accountModel)
        XCTAssertEqual(fixture.factoryCalls, 1)
    }

    func testExistingAccountStateNeverExposesChangeServerBeforePrepare() throws {
        let bundled = try CentralServerConfiguration(originText: "https://plainpost-api.olhapi.com")
        let fixture = Fixture(bundled: bundled.canonicalDocument)
        try fixture.credentials.commitProvisionalActivation(
            AccountActivation(
                accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
                deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
                mode: .pending
            ),
            genesisMaterial: nil
        )

        XCTAssertNotNil(fixture.model.accountModel)
        XCTAssertFalse(fixture.model.canChangeServer)
    }

    func testContinueConstructsOnlyAfterManualBindingSucceeds() async throws {
        let fixture = Fixture(bundled: nil)
        await fixture.model.save(originText: "https://manual.example")
        XCTAssertEqual(fixture.model.selectedServer, try CentralServerConfiguration(originText: "https://manual.example"))
        XCTAssertEqual(fixture.factoryCalls, 1)
    }

    func testChangeServerCancelsAndTearsDownBeforePristineCASReplacement() async throws {
        let first = try CentralServerConfiguration(originText: "https://first.example")
        let fixture = Fixture(bundled: first.canonicalDocument)
        await fixture.model.changeServer()
        XCTAssertTrue(fixture.model.showsSetup)
        XCTAssertNil(fixture.model.accountModel)
        XCTAssertEqual(fixture.shutdownCalls, 1)

        await fixture.model.save(originText: "https://second.example")
        XCTAssertEqual(fixture.model.selectedServer, try CentralServerConfiguration(originText: "https://second.example"))
        XCTAssertEqual(fixture.factoryCalls, 2)
    }

    func testChangeServerImmediatelyRetiresOldModelWhileShutdownDrains() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.launch.race")
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let server = try CentralServerConfiguration(originText: "https://first.example")
        let gate = LaunchShutdownGate()
        var factoryCalls = 0
        let launch = PlainpostAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: store),
            store: store,
            credentials: credentials,
            bundledDocument: server.canonicalDocument,
            makeAccountModel: { _ in
                factoryCalls += 1
                return AccountSessionViewModel(prepareSession: { _ in .signInRequired })
            },
            shutdownAccountModel: { _ in await gate.drain() }
        )

        let change = Task { await launch.changeServer() }
        await gate.waitUntilStarted()
        XCTAssertTrue(launch.isChangingServer)
        XCTAssertNil(launch.accountModel)
        XCTAssertFalse(launch.showsSetup)
        await launch.save(originText: "https://second.example")
        XCTAssertEqual(try store.loadSelection(), server.canonicalSelectionRecord)
        XCTAssertEqual(factoryCalls, 1)
        await gate.finish()
        await change.value
        XCTAssertTrue(launch.showsSetup)
    }

    func testChangeServerDrainsCancellationIgnoringBootstrapBeforeRejectingRebind() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.launch.commit-race")
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let first = try CentralServerConfiguration(originText: "https://first.example")
        let session = AccountSession(credentials: try AccountSessionCredentials(
            accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            accessToken: "access",
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshCredential: Data(repeating: 7, count: 32),
            offlineLease: "lease"
        ))
        let gate = BootstrapCommitGate()
        var factoryCalls = 0
        let launch = PlainpostAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: store),
            store: store,
            credentials: credentials,
            bundledDocument: first.canonicalDocument,
            makeAccountModel: { _ in
                factoryCalls += 1
                return AccountSessionViewModel(
                    prepareSession: { _ in .signInRequired },
                    bootstrapAppleCredential: { _, _ in
                        await gate.waitForRelease()
                        try credentials.saveSession(session)
                        return .active
                    }
                )
            }
        )
        let oldModel = try XCTUnwrap(launch.accountModel)
        let attempt = try oldModel.beginAppleSignIn()
        oldModel.submitAppleIdentityToken(Data("identity-token".utf8), for: attempt.id)
        await gate.waitUntilStarted()

        let change = Task { await launch.changeServer() }
        while !launch.isChangingServer { await Task.yield() }
        await gate.finish()
        await change.value
        await launch.save(originText: "https://second.example")

        XCTAssertEqual(try store.loadSelection(), first.canonicalSelectionRecord)
        XCTAssertEqual(factoryCalls, 1)
        guard case .originMismatch = launch.repair?.reason else { return XCTFail("expected bound-origin repair") }
    }
}

private actor LaunchShutdownGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func drain() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor BootstrapCommitGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitForRelease() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class Fixture {
    let secrets = InMemoryAccountSecretStore()
    let credentials: AccountCredentialStore
    let store: KeychainCentralServerConfigurationStore
    var factoryCalls = 0
    var shutdownCalls = 0
    lazy var model = PlainpostAccountLaunchModel(
        resolver: CentralServerConfigurationResolver(store: store),
        store: store,
        credentials: credentials,
        bundledDocument: bundled,
        makeAccountModel: { [unowned self] _ in
            self.factoryCalls += 1
            return AccountSessionViewModel(prepareSession: { _ in .signInRequired })
        },
        shutdownAccountModel: { [unowned self] model in
            model.cancel()
            self.shutdownCalls += 1
        }
    )
    private let bundled: Data?

    init(bundled: Data?) {
        self.bundled = bundled
        credentials = AccountCredentialStore(secretStore: secrets, service: "test.launch.\(UUID().uuidString)")
        store = KeychainCentralServerConfigurationStore(secretStore: secrets)
    }
}
