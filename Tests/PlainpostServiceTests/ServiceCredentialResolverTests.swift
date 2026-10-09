import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostTestSupport
@testable import PlainpostService

final class ServiceCredentialResolverTests: XCTestCase {
    func testCompositionWithoutPackagedGoogleClientFailsOnlyGoogleAccounts() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let passwordAccount = fixture.account(id: "acc-password", port: 1)
        let googleAccount = fixture.googleAccount(email: "me@gmail.com")
        try fixture.store.cacheAccounts([passwordAccount, googleAccount])
        try await fixture.assembly.vault.store(Data("pw".utf8), for: MailCredentialKeys.imapPassword(passwordAccount.id))

        let credentials = PlainpostServiceComposition.makeMailCredentials(
            store: fixture.store, vault: fixture.assembly.vault, bundle: try fixture.bundle(values: [:]),
            http: RefusingGoogleHTTP())

        XCTAssertNil(credentials.googleOAuthTokens)
        let password = try await credentials.resolver.imapAuthentication(for: passwordAccount)
        XCTAssertEqual(password, .password("pw"))
        try fixture.store.setAccountAuthentication(accountID: googleAccount.id, method: .googleOAuth, state: .ready)
        try await fixture.assembly.vault.store(Data("1//refresh".utf8), for: MailCredentialKeys.googleRefreshToken(googleAccount.id))
        do {
            _ = try await credentials.resolver.imapAuthentication(for: googleAccount)
            XCTFail("Google account authenticated without a packaged client")
        } catch MailCredentialError.oauthNotConfigured {}
    }

    func testCompositionWithPackagedGoogleClientRefreshesThroughTheInjectedHTTP() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.googleAccount(email: "me@gmail.com")
        try fixture.store.cacheAccounts([account])
        try fixture.store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        try await fixture.assembly.vault.store(Data("1//refresh".utf8), for: MailCredentialKeys.googleRefreshToken(account.id))
        let bundle = try fixture.bundle(values: [
            GoogleOAuthDesktopClient.clientIDInfoKey: "123-desktop.apps.googleusercontent.com",
            GoogleOAuthDesktopClient.clientSecretInfoKey: "fixture-secret",
        ])

        let credentials = PlainpostServiceComposition.makeMailCredentials(
            store: fixture.store, vault: fixture.assembly.vault, bundle: bundle, http: TokenGoogleHTTP())

        XCTAssertNotNil(credentials.googleOAuthTokens)
        let authentication = try await credentials.resolver.smtpAuthentication(for: account)
        XCTAssertEqual(authentication, .xoauth2(accessToken: "service-access"))
    }

    func testServiceIMAPReadsUseTheInjectedResolverBeforeAnyConnection() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.googleAccount(email: "me@gmail.com")
        try fixture.store.cacheAccounts([account])
        try fixture.store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        let http = CountingGoogleHTTP()
        let resolver = MailCredentialResolver(
            store: fixture.store, credentials: fixture.assembly.vault,
            googleTokens: GoogleAccessTokenProvider(
                store: fixture.store, credentials: fixture.assembly.vault,
                tokens: GoogleOAuthTokenClient(client: GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")!, http: http)))
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL,
            store: fixture.store,
            assembly: fixture.assembly,
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() },
            credentialResolver: resolver
        )
        await operations.reopenRuntimeConstruction()

        do {
            _ = try await operations.performSmartInboxBatch(
                PlainpostSmartInboxBatchRequest(
                    accountID: account.id.rawValue, category: "seen", action: "archive_read", archiveMailbox: "Archive"))
            XCTFail("reauthorization-required account reached IMAP")
        } catch MailCredentialError.reauthorizationRequired {}

        let count = await http.count
        XCTAssertEqual(count, 0)
    }

    func testGoogleForegroundOperationsDispatchToTheAccountRuntime() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.account(id: "acc-custom", port: 1)
        try fixture.store.cacheAccounts([account])
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL,
            store: fixture.store,
            assembly: fixture.assembly,
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() }
        )
        await operations.reopenRuntimeConstruction()

        do {
            _ = try await operations.perform(.replaceGoogleAccountCredential(
                PlainpostGoogleCredentialReplacementPayload(
                    accountID: account.id.rawValue, identity: "me@example.com", accessToken: "a",
                    refreshToken: "r", accessTokenExpiresAt: 1_800_000_000)))
            XCTFail("a non-Gmail account accepted a Google grant")
        } catch GoogleAccountSetupError.notGmailAccount {}
        do {
            _ = try await operations.perform(.googleAccountAdd(
                PlainpostGoogleAccountSetupPayload(
                    displayName: "Ada", email: "ada@gmail.com", identity: "ada@gmail.com", accessToken: "a",
                    refreshToken: "r", accessTokenExpiresAt: 1_800_000_000)))
            XCTFail("Google setup ran without a Desktop client")
        } catch GoogleOAuthError.notConfigured {}
        let refresh = try await fixture.assembly.vault.load(MailCredentialKeys.googleRefreshToken(AccountID("acc_ada_gmail_com")))
        XCTAssertNil(refresh)
    }

    func testVaultLockdownForgetsCachedGoogleAccessTokens() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.googleAccount(email: "me@gmail.com")
        try fixture.store.cacheAccounts([account])
        try fixture.store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        try await fixture.assembly.vault.store(Data("1//refresh".utf8), for: MailCredentialKeys.googleRefreshToken(account.id))
        let http = CountingTokenGoogleHTTP()
        let resolver = fixture.resolver(http: http)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL, store: fixture.store, assembly: fixture.assembly,
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() }, credentialResolver: resolver)
        await operations.reopenRuntimeConstruction()

        _ = try await resolver.smtpAuthentication(for: account)
        _ = try await resolver.smtpAuthentication(for: account)
        let cachedCount = await http.count
        XCTAssertEqual(cachedCount, 1)

        await operations.beginVaultLockdown()

        _ = try await resolver.smtpAuthentication(for: account)
        let afterLockdown = await http.count
        XCTAssertEqual(afterLockdown, 2, "lockdown must not leave an access token cached")
    }

    func testAccountDeletionForgetsTheCachedGoogleAccessToken() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.account(id: "acc-delete-google", port: 1)
        try fixture.store.cacheAccounts([account])
        try fixture.store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        try await fixture.assembly.vault.store(Data("1//refresh".utf8), for: MailCredentialKeys.googleRefreshToken(account.id))
        let http = CountingTokenGoogleHTTP()
        let provider = GoogleAccessTokenProvider(
            store: fixture.store, credentials: fixture.assembly.vault,
            tokens: GoogleOAuthTokenClient(client: GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")!, http: http))
        let resolver = MailCredentialResolver(store: fixture.store, credentials: fixture.assembly.vault, googleTokens: provider)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL, store: fixture.store, assembly: fixture.assembly,
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() }, credentialResolver: resolver)
        await operations.reopenRuntimeConstruction()
        let token = try await provider.accessToken(for: account.id)
        XCTAssertEqual(token, "service-access")

        _ = try await operations.perform(.deleteAccount(PlainpostAccountDeletionPayload(accountID: account.id.rawValue)))

        do {
            _ = try await provider.accessToken(for: account.id)
            XCTFail("a deleted account's access token stayed cached")
        } catch MailCredentialError.unavailable {}
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testReauthorizationEnqueuesAnInboxSyncThatResumesThePausedJob() async throws {
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@gmail.com"))
        try fixture.store.cacheAccounts([account])
        try fixture.store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        try await fixture.assembly.vault.store(Data("1//old".utf8), for: MailCredentialKeys.googleRefreshToken(account.id))
        let paused = try fixture.store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .realTimeSignal, scope: .incremental))
        let pausing = LocalOperationRuntime(
            store: fixture.store, credentials: fixture.assembly.vault, allowedJobKinds: [.inboxSync])
        let processed = try await pausing.processNextJob()
        XCTAssertEqual(processed?.id, paused.id)
        XCTAssertEqual(processed?.state, .paused)

        let http = CountingTokenGoogleHTTP(profileEmail: "ada@gmail.com")
        let resolver = fixture.resolver(http: http)
        let tokens = GoogleOAuthTokenClient(client: GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")!, http: http)
        let wake = ResolverRecordingWakeScheduler()
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL, store: fixture.store, assembly: fixture.assembly,
            backgroundJobWakeScheduler: wake,
            accountRuntimeFactory: {
                AccountSetupService(
                    store: fixture.store, credentials: fixture.assembly.vault,
                    imapClientFactory: { _, _ in XOAUTH2AcceptingIMAPClient() },
                    googleOAuthTokens: tokens, credentialResolver: resolver)
            },
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() }, credentialResolver: resolver)
        await operations.reopenRuntimeConstruction()

        _ = try await operations.perform(.replaceGoogleAccountCredential(
            PlainpostGoogleCredentialReplacementPayload(
                accountID: account.id.rawValue, identity: "ada@gmail.com", accessToken: "access-new",
                refreshToken: "1//new", accessTokenExpiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)))

        XCTAssertEqual(try fixture.store.accountAuthentication(accountID: account.id).state, .ready)
        let resumed = try fixture.store.job(id: paused.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        let scheduledAt = await wake.scheduledAt
        XCTAssertNotNil(scheduledAt, "the background wake must run the resumed sync")
    }

    func testServiceIMAPReadsKeepPasswordAccountsOnTheExistingVaultKeys() async throws {
        let password = "service-resolver-secret"
        let message = PlainpostFixtures.aliceMessage.withSeen(true)
        let imap = LocalIMAPServer(
            username: "me@example.com", password: password, message: message, extraMailboxes: [.init(path: "Archive")]
        )
        try await imap.start()
        defer { imap.stop() }
        let fixture = try await ResolverServiceFixture()
        defer { fixture.cleanup() }
        let account = fixture.account(id: "acc-password-batch", port: imap.port)
        try fixture.store.cacheAccounts([account])
        try await fixture.assembly.vault.store(Data(password.utf8), for: MailCredentialKeys.imapPassword(account.id))
        let credentials = PlainpostServiceComposition.makeMailCredentials(
            store: fixture.store, vault: fixture.assembly.vault, bundle: try fixture.bundle(values: [:]),
            http: RefusingGoogleHTTP())
        let operations = PlainpostServiceOperations(
            applicationSupportURL: fixture.applicationSupportURL,
            store: fixture.store,
            assembly: fixture.assembly,
            mailMonitorFactory: { _ in ResolverNoopMailMonitor() },
            credentialResolver: credentials.resolver,
            googleOAuthTokens: credentials.googleOAuthTokens
        )
        await operations.reopenRuntimeConstruction()

        let result = try await operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(
                accountID: account.id.rawValue, category: "seen", action: "archive_read", archiveMailbox: "Archive"))

        XCTAssertEqual(result.affectedMessageIDs, [])
        XCTAssertEqual(imap.loginAttempts.count, 1)
    }
}

private final class ResolverServiceFixture: @unchecked Sendable {
    let applicationSupportURL: URL
    let store: SQLiteMailStore
    let assembly: SQLiteCredentialVaultAssembly

    init() async throws {
        applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: applicationSupportURL.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        assembly = SQLiteCredentialVaultAssembly(store: store, provider: ResolverFixedVaultKeyProvider())
        try await assembly.unlockForeground(prompt: "Test-only in-memory vault unlock")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    func resolver(http: any GoogleOAuthHTTP) -> MailCredentialResolver {
        MailCredentialResolver(
            store: store, credentials: assembly.vault,
            googleTokens: GoogleAccessTokenProvider(
                store: store, credentials: assembly.vault,
                tokens: GoogleOAuthTokenClient(client: GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")!, http: http)))
    }

    func account(id: String, port: UInt16) -> Account {
        Account(
            id: AccountID(id), displayName: "Personal", email: EmailAddress("me@example.com"),
            username: "me@example.com", sentMailbox: "Sent", imapHost: "127.0.0.1", imapPort: port,
            smtpHost: "127.0.0.1", smtpPort: 1)
    }

    func googleAccount(email: String) -> Account {
        MailProviderProfile.gmail.makeGoogleAccount(displayName: "Personal", email: EmailAddress(email))
    }

    func bundle(values: [String: String]) throws -> Bundle {
        let url = applicationSupportURL.appendingPathComponent("Fixture-\(UUID().uuidString).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": "com.olhapi.fixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        info.merge(values) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: url))
    }
}

private actor ResolverFixedVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x52, count: 32)
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { key }
    func countMatchingItems() async throws -> Int { 1 }
}

private actor ResolverNoopMailMonitor: ServiceMailMonitoring {
    func start() {}
    func stop() {}
}

private struct RefusingGoogleHTTP: GoogleOAuthHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTFail("unexpected Google request")
        throw URLError(.cannotConnectToHost)
    }
}

private struct TokenGoogleHTTP: GoogleOAuthHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data(#"{"access_token":"service-access","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor CountingGoogleHTTP: GoogleOAuthHTTP {
    private(set) var count = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        throw URLError(.cannotConnectToHost)
    }
}

/// Answers token refreshes with `service-access` and the Gmail profile with
/// `profileEmail`, counting refreshes only.
private actor CountingTokenGoogleHTTP: GoogleOAuthHTTP {
    private let profileEmail: String
    private(set) var count = 0

    init(profileEmail: String = "me@example.com") {
        self.profileEmail = profileEmail
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: String
        if url.path == "/gmail/v1/users/me/profile" {
            body = #"{"emailAddress":"\#(profileEmail)","historyId":"1","messagesTotal":0,"threadsTotal":0}"#
        } else {
            count += 1
            body = #"{"access_token":"service-access","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor ResolverRecordingWakeScheduler: BackgroundJobWakeScheduling {
    private(set) var scheduledAt: Date?

    func replaceWake(at date: Date?, action: @escaping @Sendable () async -> Void) {
        scheduledAt = date
    }
}

/// Accepts any XOAUTH2 authentication; every mailbox command fails.
private struct XOAUTH2AcceptingIMAPClient: IMAPClientProtocol {
    func authenticate(username: String, authentication: MailAuthentication) async throws {
        guard case .xoauth2 = authentication else { throw IMAPClientError.authenticationFailed }
    }

    func login(username: String, password: String) async throws { throw IMAPClientError.authenticationFailed }
    func listMailboxes() async throws -> [Mailbox] { throw IMAPClientError.connectionFailed }
    func selectMailbox(_ path: String) async throws -> String { throw IMAPClientError.connectionFailed }
    func allMessageUIDs() async throws -> [Int] { throw IMAPClientError.connectionFailed }
    func fetchHeader(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func fetchBody(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func markRead(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func markUnread(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func archive(uid: Int, archiveMailbox: String) async throws { throw IMAPClientError.connectionFailed }
    func delete(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        throw IMAPClientError.connectionFailed
    }
}
