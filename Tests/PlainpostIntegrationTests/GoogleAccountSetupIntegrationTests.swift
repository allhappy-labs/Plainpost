import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

final class GoogleAccountSetupIntegrationTests: XCTestCase {
    func testAddGoogleAccountStoresOnlyRefreshTokenAndSyncsWithXOAUTH2() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let tokens = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
            http: GoogleProfileFixtureHTTP(emailAddress: "ada@example.test"))
        let service = AccountSetupService(store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: tokens)
        let grant = GoogleTokenGrant(accessToken: "access-1", refreshToken: "1//refresh", expiresAt: Date().addingTimeInterval(3600))
        let result = try await service.addGoogleAccount(GoogleAccountSetupRequest(displayName: "Ada", email: EmailAddress("ada@example.test"), grant: grant), identity: "ada@example.test", progress: { _ in })
        XCTAssertEqual(try store.accountAuthentication(accountID: result.account.id).method, .googleOAuth)
        let storedRefreshToken = try await vault.load(MailCredentialKeys.googleRefreshToken(result.account.id))
        XCTAssertEqual(storedRefreshToken, Data("1//refresh".utf8))
        let storedPassword = try await vault.load(MailCredentialKeys.imapPassword(result.account.id))
        XCTAssertNil(storedPassword)
        XCTAssertFalse(fixture.transcript.contains("LOGIN "))

        XCTAssertEqual(result.account.imapHost, "imap.gmail.com")
        XCTAssertEqual(result.account.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(result.account.username, "ada@example.test")
        XCTAssertEqual(try store.accountAuthentication(accountID: result.account.id).state, .ready)
        let smtpPassword = try await vault.load(MailCredentialKeys.smtpPassword(result.account.id))
        XCTAssertNil(smtpPassword)
        XCTAssertGreaterThanOrEqual(fixture.acceptedAuthenticationCount, 3, "IMAP verification, SMTP verification and the first sync")
        XCTAssertEqual(fixture.acceptedMessageCount, 1, "one verification message")
        assertNoTokenText(in: store, fixture: fixture, tokens: ["access-1", "1//refresh"])
    }

    func testAddGoogleAccountRefusesWhenServiceVerifiedIdentityDiffersFromCallerIdentity() async throws {
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let tokens = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
            http: GoogleProfileFixtureHTTP(emailAddress: "mallory@example.test"))
        let service = AccountSetupService(store: store, credentials: InMemoryCredentialVault(),
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: 9) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: 9) },
            googleOAuthTokens: tokens)
        let grant = GoogleTokenGrant(accessToken: "access-1", refreshToken: "1//refresh", expiresAt: Date().addingTimeInterval(3600))
        do {
            _ = try await service.addGoogleAccount(GoogleAccountSetupRequest(displayName: "Ada", email: EmailAddress("ada@example.test"), grant: grant), identity: "ada@example.test", progress: { _ in })
            XCTFail("caller-supplied identity was trusted")
        } catch GoogleAccountSetupError.identityMismatch(let expected) {
            XCTAssertEqual(expected, "ada@example.test")
        }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testAddGoogleAccountWithoutDesktopClientIsNotConfigured() async throws {
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = AccountSetupService(store: store, credentials: InMemoryCredentialVault())
        let grant = GoogleTokenGrant(accessToken: "access-1", refreshToken: "1//refresh", expiresAt: Date().addingTimeInterval(3600))
        do {
            _ = try await service.addGoogleAccount(
                GoogleAccountSetupRequest(displayName: "Ada", email: EmailAddress("ada@example.test"), grant: grant),
                identity: "ada@example.test", progress: { _ in })
            XCTFail("setup ran without a Desktop client")
        } catch GoogleOAuthError.notConfigured {}
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testReauthorizeConvertsAppPasswordGmailAccountAndErasesBothPasswords() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-2")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@example.test"))
        try store.cacheAccounts([account])
        let vault = InMemoryCredentialVault(records: [
            MailCredentialKeys.imapPassword(account.id): Data("abcdefghijklmnop".utf8),
            MailCredentialKeys.smtpPassword(account.id): Data("abcdefghijklmnop".utf8),
        ])
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .password)
        let service = AccountSetupService(store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: GoogleOAuthTokenClient(client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")),
                                                     http: GoogleProfileFixtureHTTP(emailAddress: "ada@example.test")))

        try await service.replaceGoogleCredential(
            accountID: account.id,
            grant: GoogleTokenGrant(accessToken: "access-2", refreshToken: "1//new", expiresAt: Date().addingTimeInterval(3600)),
            identity: "ada@example.test")

        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .googleOAuth)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        let imap = try await vault.load(MailCredentialKeys.imapPassword(account.id))
        let smtp = try await vault.load(MailCredentialKeys.smtpPassword(account.id))
        let refresh = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertNil(imap)
        XCTAssertNil(smtp)
        XCTAssertEqual(refresh, Data("1//new".utf8))
        XCTAssertEqual(fixture.acceptedAuthenticationCount, 1)
    }

    func testReauthorizeLeavesCredentialsUntouchedWhenGmailRejectsTheNewGrantOrIdentityDiffers() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-good")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@example.test"))
        try store.cacheAccounts([account])
        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//old".utf8)])
        func service(identity: String) throws -> AccountSetupService {
            AccountSetupService(store: store, credentials: vault,
                imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
                smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
                googleOAuthTokens: GoogleOAuthTokenClient(client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")),
                                                         http: GoogleProfileFixtureHTTP(emailAddress: identity)))
        }

        do {
            try await service(identity: "ada@example.test").replaceGoogleCredential(
                accountID: account.id,
                grant: GoogleTokenGrant(accessToken: "access-rejected", refreshToken: "1//new", expiresAt: Date().addingTimeInterval(3600)),
                identity: "ada@example.test")
            XCTFail("a grant Gmail rejected was installed")
        } catch MailAuthenticationError.rejected {}
        do {
            try await service(identity: "mallory@example.test").replaceGoogleCredential(
                accountID: account.id,
                grant: GoogleTokenGrant(accessToken: "access-good", refreshToken: "1//new", expiresAt: Date().addingTimeInterval(3600)),
                identity: "ada@example.test")
            XCTFail("a grant for another Google account was installed")
        } catch GoogleAccountSetupError.identityMismatch(let expected) {
            XCTAssertEqual(expected, "ada@example.test")
        }

        let refresh = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertEqual(refresh, Data("1//old".utf8))
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
    }

    /// A Sync Node account signs in with Google on this device as the mailbox its Node
    /// serves; the account stays a Sync Node account.
    func testASyncNodeAccountSignsInAsTheMailboxItsNodeServes() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-2")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@example.test"))
        try store.cacheAccounts([account])
        func node(_ identity: String) throws -> AccountMailSource {
            let current = try store.mailSource(accountID: account.id)
            return try store.replaceMailSource(current.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff", logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: identity), expectedGeneration: current.generation)
        }
        let vault = InMemoryCredentialVault()
        let service = AccountSetupService(store: store, credentials: vault,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: GoogleOAuthTokenClient(client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")),
                                                     http: GoogleProfileFixtureHTTP(emailAddress: "ada@example.test")))
        let grant = GoogleTokenGrant(accessToken: "access-2", refreshToken: "1//new", expiresAt: Date().addingTimeInterval(3600))

        let elsewhere = try node("someone-else@gmail.com")
        do {
            try await service.replaceGoogleCredential(accountID: account.id, grant: grant, identity: "ada@example.test")
            XCTFail("a sign-in for another mailbox than the Node's was installed")
        } catch GoogleAccountSetupError.identityMismatch(let expected) {
            XCTAssertEqual(expected, "someone-else@gmail.com")
        }
        let none = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertNil(none)

        _ = try store.replaceMailSource(elsewhere.revertedToDirect(), expectedGeneration: elsewhere.generation)
        let source = try node("ADA@example.test")
        try await service.replaceGoogleCredential(accountID: account.id, grant: grant, identity: "ada@example.test")
        let refresh = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertEqual(refresh, Data("1//new".utf8))
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .googleOAuth)
        XCTAssertEqual(try store.mailSource(accountID: account.id), source, "the account stays with its Node")
        let stored = await MailProviderSignIn.isStored(accountID: account.id, store: store, credentials: vault)
        XCTAssertTrue(stored)
    }

    func testReauthorizeRefusesNonGmailAccounts() async throws {
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(id: AccountID("acc_custom"), displayName: "Custom", email: EmailAddress("me@example.com"),
                              imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try store.cacheAccounts([account])
        let service = AccountSetupService(store: store, credentials: InMemoryCredentialVault(),
            googleOAuthTokens: GoogleOAuthTokenClient(client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "id", clientSecret: "secret")),
                                                     http: GoogleProfileFixtureHTTP(emailAddress: "me@example.com")))
        do {
            try await service.replaceGoogleCredential(
                accountID: account.id,
                grant: GoogleTokenGrant(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)),
                identity: "me@example.com")
            XCTFail("a non-Gmail account accepted a Google grant")
        } catch GoogleAccountSetupError.notGmailAccount {}
    }

    func testGoogleSetupRequestRedactsTheGrant() {
        let request = GoogleAccountSetupRequest(
            displayName: "Ada", email: EmailAddress("ada@example.test"),
            grant: GoogleTokenGrant(accessToken: "ya29.secret", refreshToken: "1//secret", expiresAt: Date()))
        var dumped = ""
        dump(request, to: &dumped)
        for rendering in [String(describing: request), String(reflecting: request), dumped] {
            XCTAssertFalse(rendering.contains("secret"), rendering)
        }
    }

    func testSMTPDeliveryRefreshesARefusedTokenAndSendsExactlyOnce() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-refreshed")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.gmail.makeGoogleAccount(displayName: "Ada", email: EmailAddress("ada@example.test"))
        try store.cacheAccounts([account])
        let vault = InMemoryCredentialVault()
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(
                store: store, credentials: vault,
                tokens: GoogleOAuthTokenClient(
                    client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")),
                    http: GoogleRefreshFixtureHTTP(accessToken: "access-refreshed"))))
        try await resolver.installGoogleGrant(
            accessToken: "access-expired", expiresAt: Date().addingTimeInterval(3600), for: account.id
        ) {
            try await vault.store(Data("1//refresh".utf8), for: MailCredentialKeys.googleRefreshToken(account.id))
            try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        }

        let smtp = resolver.tokenRefreshingSMTPClient(for: account) {
            MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort)
        }
        let first = try await resolver.smtpAuthentication(for: account)
        try await smtp.send(
            username: account.username, authentication: first, from: account.email,
            to: [EmailAddress("fixture@example.test")], data: "Subject: t\r\n\r\nbody")

        XCTAssertEqual(fixture.acceptedMessageCount, 1)
        XCTAssertEqual(fixture.transcript.components(separatedBy: "AUTH XOAUTH2 <xoauth2>").count - 1, 2)
        XCTAssertEqual(fixture.transcript.components(separatedBy: "MAIL FROM").count - 1, 1)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
    }

    func testDirectGoogleSetupRollsBackGrantAndAccountWhenInitialSyncFails() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let tokenClient = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthPublicClient(
                clientID: "123-abc.apps.googleusercontent.com",
                registeredSchemes: ["com.googleusercontent.apps.123-abc"])),
            http: GoogleProfileFixtureHTTP(emailAddress: "ada@example.test"))
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: vault, tokens: tokenClient))
        let service = AccountSetupService(
            store: store, credentials: vault,
            inboxSyncOrchestrator: FailingGoogleFirstSync(),
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: tokenClient, credentialResolver: resolver,
            publishDirectMailSource: true)
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: "Ada", email: EmailAddress("ada@example.test"))
        await XCTAssertThrowsAsync(try await service.addGoogleAccount(
            GoogleAccountSetupRequest(displayName: "Ada", email: account.email,
                                      grant: GoogleTokenGrant(accessToken: "access-1", refreshToken: "refresh-1",
                                                              expiresAt: Date().addingTimeInterval(3600))),
            identity: account.email.rawValue, progress: { _ in }))
        XCTAssertTrue(store.accounts.isEmpty)
        let refresh = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertNil(refresh)
    }

    func testDirectGoogleSetupRollsBackWhenCancelledDuringFirstSync() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault()
        let tokenClient = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthPublicClient(
                clientID: "123-abc.apps.googleusercontent.com",
                registeredSchemes: ["com.googleusercontent.apps.123-abc"])),
            http: GoogleProfileFixtureHTTP(emailAddress: "ada@example.test"))
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: vault, tokens: tokenClient))
        let syncer = CancellationIgnoringGoogleFirstSync()
        let service = AccountSetupService(
            store: store, credentials: vault, inboxSyncOrchestrator: syncer,
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: tokenClient, credentialResolver: resolver,
            publishDirectMailSource: true)
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: "Ada", email: EmailAddress("ada@example.test"))
        let task = Task {
            try await service.addGoogleAccount(
                GoogleAccountSetupRequest(displayName: "Ada", email: account.email,
                                          grant: GoogleTokenGrant(accessToken: "access-1", refreshToken: "refresh-1",
                                                                  expiresAt: Date().addingTimeInterval(3600))),
                identity: account.email.rawValue, progress: { _ in })
        }
        for _ in 0..<200 where !syncer.started {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(syncer.started)
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) {
            XCTAssertTrue($0 is CancellationError, "Received \($0)")
        }
        XCTAssertTrue(store.accounts.isEmpty)
        let refresh = try await vault.load(MailCredentialKeys.googleRefreshToken(account.id))
        XCTAssertNil(refresh)
    }

    func testDirectGoogleSetupReportsCleanupFailureAndLeavesAccountDiscoverable() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let (store, url) = try makeTemporaryStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: "Ada", email: EmailAddress("ada@example.test"))
        let vault = FailingGoogleCleanupVault(blockedKey: MailCredentialKeys.googleRefreshToken(account.id))
        let tokenClient = GoogleOAuthTokenClient(
            client: try XCTUnwrap(GoogleOAuthPublicClient(
                clientID: "123-abc.apps.googleusercontent.com",
                registeredSchemes: ["com.googleusercontent.apps.123-abc"])),
            http: GoogleProfileFixtureHTTP(emailAddress: account.email.rawValue))
        let resolver = MailCredentialResolver(
            store: store, credentials: vault,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: vault, tokens: tokenClient))
        let service = AccountSetupService(
            store: store, credentials: vault, inboxSyncOrchestrator: FailingGoogleFirstSync(),
            imapClientFactory: { _, _ in MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort) },
            smtpClientFactory: { _, _ in MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort) },
            googleOAuthTokens: tokenClient, credentialResolver: resolver,
            publishDirectMailSource: true)
        await XCTAssertThrowsAsync(try await service.addGoogleAccount(
            GoogleAccountSetupRequest(displayName: "Ada", email: account.email,
                                      grant: GoogleTokenGrant(accessToken: "access-1", refreshToken: "refresh-1",
                                                              expiresAt: Date().addingTimeInterval(3600))),
            identity: account.email.rawValue, progress: { _ in })) {
                XCTAssertEqual($0 as? GoogleAccountSetupError, .cleanupFailed(accountID: account.id))
            }
        XCTAssertEqual(store.accounts.map(\.id), [account.id])
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .googleOAuth)
        try store.requireDirectMailSource(accountID: account.id)
    }

    private func assertNoTokenText(in store: SQLiteMailStore, fixture: XOAUTH2MailFixture, tokens: [String],
                                   file: StaticString = #filePath, line: UInt = #line) {
        let audit = store.auditEntries.map { "\($0)" }.joined(separator: "\n")
        let artifacts = (try? store.jobs(limit: 200).map { "\($0)" }.joined(separator: "\n")) ?? ""
        for token in tokens {
            XCTAssertFalse(audit.contains(token), "audit entries contain token text", file: file, line: line)
            XCTAssertFalse(artifacts.contains(token), "jobs contain token text", file: file, line: line)
            XCTAssertFalse(fixture.transcript.contains(token), "transcript contains token text", file: file, line: line)
        }
    }

    private func makeTemporaryStore(testName: String) throws -> (SQLiteMailStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-google-setup-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return (store, url)
    }
}

private struct FailingGoogleFirstSync: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        throw PlainpostError.validationFailed("Fixture sync failure")
    }
}

private final class CancellationIgnoringGoogleFirstSync: AccountInboxSyncOrchestrating, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    var started: Bool { lock.withLock { began } }

    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        lock.withLock { began = true }
        do { try await Task.sleep(for: .seconds(30)) } catch { }
        return IMAPSyncResult(syncedMessageCount: 0)
    }
}

private actor FailingGoogleCleanupVault: CredentialVault {
    private let blockedKey: CredentialRecordKey
    private var records: [CredentialRecordKey: Data] = [:]

    init(blockedKey: CredentialRecordKey) { self.blockedKey = blockedKey }

    func store(_ secret: Data, for key: CredentialRecordKey) throws { records[key] = secret }
    func load(_ key: CredentialRecordKey) throws -> Data? { records[key] }
    func remove(_ key: CredentialRecordKey) throws {
        if key == blockedKey { throw CredentialVaultError.locked }
        records.removeValue(forKey: key)
    }
    func loadOrCreate(
        _ keys: [CredentialRecordKey], create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        let current = keys.map { records[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        for (key, value) in zip(keys, created) { records[key] = value }
        return created.map(Optional.some)
    }
}

private struct GoogleProfileFixtureHTTP: GoogleOAuthHTTP {
    let emailAddress: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        guard url.path == "/gmail/v1/users/me/profile" else { throw GoogleOAuthError.unavailable }
        let body = Data(#"{"emailAddress":"\#(emailAddress)","historyId":"1","messagesTotal":0,"threadsTotal":0}"#.utf8)
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])))
    }
}

private struct GoogleRefreshFixtureHTTP: GoogleOAuthHTTP {
    let accessToken: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        guard url.path == "/token" else { throw GoogleOAuthError.unavailable }
        let body = Data(#"{"access_token":"\#(accessToken)","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#.utf8)
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])))
    }
}
