import Foundation
import XCTest
@testable import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

final class GoogleAccessTokenProviderTests: XCTestCase {
    func testInvalidGrantMarksReauthorizationAndCoalescesConcurrentRefresh() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//revoked".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(400, #"{"error":"invalid_grant"}"#)], delay: .milliseconds(50))
        let client = GoogleOAuthTokenClient(client: try XCTUnwrap(GoogleOAuthDesktopClient(clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")), http: http)
        let provider = GoogleAccessTokenProvider(store: store, credentials: vault, tokens: client)
        async let first = Result { try await provider.accessToken(for: account.id) }
        async let second = Result { try await provider.accessToken(for: account.id) }
        for result in await [first, second] {
            XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired) }
        }
        let requestCount = await http.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
        let loggedBodies = await http.loggedBodies
        XCTAssertFalse(loggedBodies.joined().contains("1//revoked"), "fixture must not retain token bodies")
    }

    func testCachesAccessTokenAndRefreshesWithinTwoMinutesOfExpiry() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [
            (200, tokenResponse(access: "access-1", expiresIn: 3600)),
            (200, tokenResponse(access: "access-2", expiresIn: 3600)),
        ])
        let clock = MutableClock()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault,
            tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http, now: { clock.now }),
            now: { clock.now })

        let first = try await provider.accessToken(for: account.id)
        clock.advance(by: 3600 - 121)
        let cached = try await provider.accessToken(for: account.id)
        clock.advance(by: 2)
        let refreshed = try await provider.accessToken(for: account.id)

        XCTAssertEqual([first, cached, refreshed], ["access-1", "access-1", "access-2"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.path, "/token")
        XCTAssertEqual(requests.first?.formKeys, ["client_id", "client_secret", "grant_type", "refresh_token"])
    }

    func testRotatedRefreshTokenReplacesVaultRecord() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-1", refresh: "1//rotated"))])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let token = try await provider.accessToken(for: account.id)

        XCTAssertEqual(token, "access-1")
        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//rotated".utf8))
    }

    func testRefusalOfAReplacedGrantDoesNotMarkReauthorization() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        try await provider.installGrant(
            accessToken: "access-new", expiresAt: Date().addingTimeInterval(3600), accountID: account.id
        ) {
            try await vault.store(Data("1//reauthorized".utf8), for: key)
        }
        await http.releaseNext(status: 400, body: #"{"error":"invalid_grant"}"#)
        await http.failFurtherRequests()

        let token = try await refresh.value
        XCTAssertEqual(token, "access-new", "a caller overtaken by reauthorization gets the new grant's token")
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//reauthorized".utf8))
        let count = await http.requestCount
        XCTAssertEqual(count, 1)
    }

    func testStaleSuccessfulRefreshNeitherOverwritesTheInstalledTokenNorRotatesTheNewRecord() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        try await provider.installGrant(
            accessToken: "access-new", expiresAt: Date().addingTimeInterval(3600), accountID: account.id
        ) {
            try await vault.store(Data("1//new".utf8), for: key)
        }
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-old-grant", refresh: "1//rotated-old"))
        await http.failFurtherRequests()

        let overtaken = try await refresh.value
        let cached = try await provider.accessToken(for: account.id)
        XCTAssertEqual(overtaken, "access-new")
        XCTAssertEqual(cached, "access-new")
        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//new".utf8))
        let count = await http.requestCount
        XCTAssertEqual(count, 1)
    }

    /// Google commits a refresh-token rotation before the client sees it, so
    /// the token the attempt started with is already dead. A vault lockdown
    /// that lands while the rotation is in flight must not drop it, or the
    /// account is left with a dead refresh token and only recovers through a
    /// later `invalid_grant`. The stale access token is still not cached.
    func testRotationDuringLockdownIsPersistedWithoutSeedingTheStaleAccessToken() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        // The vault locks down while Google is answering.
        await provider.forgetAll()
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-old-grant", refresh: "1//rotated"))
        await http.failFurtherRequests()
        _ = await Result { try await refresh.value }

        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//rotated".utf8), "Google already committed the rotation; the old token is dead")
        await XCTAssertThrowsAsync(try await provider.accessToken(for: account.id)) { _ in }
        let count = await http.requestCount
        XCTAssertGreaterThan(count, 1, "a token from a locked-down grant must not be served from the cache")
    }

    /// A forget that accompanies account deletion also moves the generation,
    /// but a rotation arriving afterwards must never write the record back.
    func testRotationAfterAccountDeletionDoesNotResurrectTheRefreshToken() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        // The account is deleted: its credential record goes, then its tokens.
        try await vault.remove(key)
        await provider.forget(accountID: account.id)
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-old-grant", refresh: "1//rotated"))
        await http.failFurtherRequests()
        _ = await Result { try await refresh.value }

        let stored = try await vault.load(key)
        XCTAssertNil(stored, "a deleted account's refresh token must not come back")
    }

    /// Mirrors `AccountSetupService.deleteAccount`: the provider forgets the
    /// account first, an in-flight refresh then lands its rotation, and only
    /// afterwards does the deletion remove the credential record.
    func testRotationBetweenForgetAndCredentialRemovalDoesNotSurviveDeletion() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        await provider.forget(accountID: account.id)
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-old-grant", refresh: "1//rotated"))
        await http.failFurtherRequests()
        _ = await Result { try await refresh.value }

        // Forget does not stop a rotation Google already committed.
        let rotated = try await vault.load(key)
        XCTAssertEqual(rotated, Data("1//rotated".utf8))
        // The deletion then removes the record unconditionally.
        try await vault.remove(key)
        await provider.forget(accountID: account.id)

        let stored = try await vault.load(key)
        XCTAssertNil(stored, "no refresh token survives a completed deletion")
    }

    /// A reauthorization installed while a refresh is in flight owns the
    /// account's refresh token, even when Google handed the new grant the same
    /// token value the stale refresh had started from.
    func testRotationAfterANewerInstallIsDroppedEvenWhenTheInstalledTokenIsUnchanged() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        try await provider.installGrant(
            accessToken: "access-new", expiresAt: Date().addingTimeInterval(3600), accountID: account.id
        ) {
            // Google re-issued the same refresh token for the new grant.
            try await vault.store(Data("1//old".utf8), for: key)
        }
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-old-grant", refresh: "1//rotated-old"))
        await http.failFurtherRequests()

        let overtaken = try await refresh.value
        XCTAssertEqual(overtaken, "access-new")
        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//old".utf8), "the installed grant's refresh token wins")
        let count = await http.requestCount
        XCTAssertEqual(count, 1)
    }

    func testGrantInstallWaitsForAnInProgressRotationWrite() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = StoreGatedCredentialVault(
            records: [key: Data("1//old".utf8)], holdingStoreOf: Data("1//rotated".utf8))
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-rotated", refresh: "1//rotated"))])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let refresh = Task { try await provider.accessToken(for: account.id) }
        await vault.waitUntilStoreIsHeld()
        let install = Task {
            try await provider.installGrant(
                accessToken: "access-new", expiresAt: Date().addingTimeInterval(3600), accountID: account.id
            ) {
                try await vault.store(Data("1//new".utf8), for: key)
            }
        }
        let installIsWaiting = await waitUntil { await provider.pendingGrantWrites(for: account.id) == 1 }
        XCTAssertTrue(installIsWaiting)
        let beforeRelease = try await vault.load(key)
        XCTAssertEqual(beforeRelease, Data("1//old".utf8), "the install must not write while a rotation is applying")
        await vault.releaseHeldStore()
        try await install.value
        _ = try await refresh.value

        let stored = try await vault.load(key)
        XCTAssertEqual(stored, Data("1//new".utf8))
        let cached = try await provider.accessToken(for: account.id)
        XCTAssertEqual(cached, "access-new")
    }

    func testForgetDropsTheCachedTokenAndOutdatesAnInFlightRefresh() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//refresh".utf8)])
        let http = GatedGoogleOAuthHTTP()
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        let first = Task { try await provider.accessToken(for: account.id) }
        let arrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(arrived)
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-1"))
        let firstToken = try await first.value
        XCTAssertEqual(firstToken, "access-1")

        await provider.forget(accountID: account.id)
        let afterForget = Task { try await provider.accessToken(for: account.id) }
        let secondArrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(secondArrived)
        await provider.forgetAll()
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-2"))
        let thirdArrived = await http.waitForPendingRequests(1)
        XCTAssertTrue(thirdArrived)
        await http.releaseNext(status: 200, body: tokenResponse(access: "access-3"))
        await http.failFurtherRequests()

        let afterForgetToken = try await afterForget.value
        XCTAssertEqual(afterForgetToken, "access-3", "a refresh outdated by lockdown is not used or cached")
        let count = await http.requestCount
        XCTAssertEqual(count, 3)
    }

    /// A vault lockdown racing a grant install (for example a reauthorization
    /// that runs inside `apply`) must not leave the newly installed access
    /// token cached: `forgetAll` can run between `apply` returning and
    /// `installGrant` seeding the cache, and that seed must be skipped.
    func testForgetAllDuringInstallGrantApplyPreventsTheGrantFromReseedingTheCache() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let key = MailCredentialKeys.googleRefreshToken(account.id)
        let vault = InMemoryCredentialVault(records: [key: Data("1//old".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-after-lockdown"))])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        try await provider.installGrant(
            accessToken: "access-new", expiresAt: Date().addingTimeInterval(3600), accountID: account.id
        ) {
            try await vault.store(Data("1//reauthorized".utf8), for: key)
            // A vault lockdown fires while this reauthorization is applying.
            await provider.forgetAll()
        }

        let token = try await provider.accessToken(for: account.id)
        XCTAssertEqual(token, "access-after-lockdown", "the lockdown-era grant must not survive as a cached token")
        let count = await http.requestCount
        XCTAssertEqual(count, 1, "the cache must have been left empty, forcing a fresh refresh")
    }

    func testMissingRefreshTokenIsUnavailableWithoutContactingGoogle() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let http = ScriptedGoogleOAuthHTTP(responses: [])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: InMemoryCredentialVault(),
            tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        await XCTAssertThrowsAsync(try await provider.accessToken(for: account.id)) {
            XCTAssertEqual($0 as? MailCredentialError, .unavailable)
        }
        let count = await http.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
    }

    func testTransportFailureLeavesStateReadyAndMissingClientIsNotConfigured() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(scripted: [.transportFailure, .response(503, "{}")])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        for _ in 0..<2 {
            await XCTAssertThrowsAsync(try await provider.accessToken(for: account.id)) {
                XCTAssertEqual($0 as? GoogleOAuthError, .unavailable)
            }
        }
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)

        let unconfigured = GoogleAccessTokenProvider(store: store, credentials: vault, tokens: nil)
        await XCTAssertThrowsAsync(try await unconfigured.accessToken(for: account.id)) {
            XCTAssertEqual($0 as? MailCredentialError, .oauthNotConfigured)
        }
    }

    func testReauthorizationRequiredAccountDoesNotContactGoogle() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        let vault = InMemoryCredentialVault(records: [MailCredentialKeys.googleRefreshToken(account.id): Data("1//refresh".utf8)])
        let http = ScriptedGoogleOAuthHTTP(responses: [(200, tokenResponse(access: "access-1"))])
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: vault, tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http))

        await XCTAssertThrowsAsync(try await provider.accessToken(for: account.id)) {
            XCTAssertEqual($0 as? MailCredentialError, .reauthorizationRequired)
        }
        let count = await http.requestCount
        XCTAssertEqual(count, 0)
    }

    func testLockedVaultPassesThrough() async throws {
        let (store, url, account) = try makeGoogleAccountStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GoogleAccessTokenProvider(
            store: store, credentials: LockedCredentialVault(),
            tokens: GoogleOAuthTokenClient(client: fixtureDesktopClient, http: ScriptedGoogleOAuthHTTP(responses: [])))

        await XCTAssertThrowsAsync(try await provider.accessToken(for: account.id)) {
            XCTAssertEqual($0 as? CredentialVaultError, .locked)
        }
    }
}

func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
