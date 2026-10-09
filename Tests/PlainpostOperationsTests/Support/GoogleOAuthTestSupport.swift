import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

/// A temporary migrated store with one Gmail account marked `google_oauth`/`ready`.
func makeGoogleAccountStore(
    testName: String,
    method: AccountAuthenticationMethod = .googleOAuth
) throws -> (SQLiteMailStore, URL, Account) {
    let safeName = testName.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("plainpost-google-oauth-\(safeName)-\(UUID().uuidString).sqlite")
    let store = try SQLiteMailStore(path: url.path)
    try store.migrate()
    let account = Account(
        id: AccountID("acc_ada_gmail_com"),
        displayName: "Ada",
        email: EmailAddress("ada@gmail.com"),
        username: "ada@gmail.com",
        sentMailbox: "[Gmail]/Sent Mail",
        imapHost: "imap.gmail.com",
        imapPort: 993,
        smtpHost: "smtp.gmail.com",
        smtpPort: 465
    )
    try store.cacheAccounts([account])
    try store.setAccountAuthentication(accountID: account.id, method: method, state: .ready)
    return (store, url, account)
}

let fixtureDesktopClient = GoogleOAuthDesktopClient(
    clientID: "123-desktop.apps.googleusercontent.com", clientSecret: "fixture-secret")!

/// Scripted Google HTTP endpoint. It records only redacted request metadata:
/// the method, path and form keys, never values or headers.
actor ScriptedGoogleOAuthHTTP: GoogleOAuthHTTP {
    struct RecordedRequest: Equatable, Sendable {
        let method: String
        let path: String
        let formKeys: [String]
    }

    enum Scripted: Sendable {
        case response(Int, String)
        case transportFailure
    }

    private var scripted: [Scripted]
    private let delay: Duration
    private(set) var requests: [RecordedRequest] = []
    private(set) var loggedBodies: [String] = []

    init(responses: [(Int, String)], delay: Duration = .zero) {
        self.scripted = responses.map { .response($0.0, $0.1) }
        self.delay = delay
    }

    init(scripted: [Scripted], delay: Duration = .zero) {
        self.scripted = scripted
        self.delay = delay
    }

    var requestCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let keys = body.split(separator: "&").map { String($0.prefix { $0 != "=" }) }.sorted()
        requests.append(RecordedRequest(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", formKeys: keys))
        loggedBodies.append(keys.joined(separator: "&"))
        if delay > .zero { try await Task.sleep(for: delay) }
        guard !scripted.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch scripted.removeFirst() {
        case .transportFailure:
            throw URLError(.notConnectedToInternet)
        case .response(let status, let text):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(text.utf8), response)
        }
    }
}

actor LockedCredentialVault: CredentialVault {
    func store(_ secret: Data, for key: CredentialRecordKey) throws { throw CredentialVaultError.locked }
    func load(_ key: CredentialRecordKey) throws -> Data? { throw CredentialVaultError.locked }
    func remove(_ key: CredentialRecordKey) throws { throw CredentialVaultError.locked }
    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        throw CredentialVaultError.locked
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

func tokenResponse(access: String, expiresIn: Int = 3599, refresh: String? = nil, scope: String = "https://mail.google.com/") -> String {
    let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
    return #"{"access_token":"\#(access)","expires_in":\#(expiresIn),"scope":"\#(scope)","token_type":"Bearer"\#(refreshField)}"#
}

/// Google HTTP endpoint whose responses the test releases one at a time, so
/// refresh interleavings are ordered by the test instead of by timing. After
/// `failFurtherRequests()` every unreleased and later request fails at once,
/// so a regression that sends an unexpected request fails instead of hanging.
actor GatedGoogleOAuthHTTP: GoogleOAuthHTTP {
    private var pending: [CheckedContinuation<(Int, String), Never>] = []
    private var failsFurtherRequests = false
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let (status, text) = failsFurtherRequests
            ? (503, "{}")
            : await withCheckedContinuation { pending.append($0) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(text.utf8), response)
    }

    /// Returns true once `count` requests are waiting, false after `timeout`.
    func waitForPendingRequests(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pending.count < count {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func releaseNext(status: Int, body: String) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: (status, body))
    }

    func failFurtherRequests() {
        failsFurtherRequests = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume(returning: (503, "{}")) }
    }
}

/// A vault that holds back one `store` of a chosen value until released.
actor StoreGatedCredentialVault: CredentialVault {
    private let base: InMemoryCredentialVault
    private let heldValue: Data
    private var heldStore: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(records: [CredentialRecordKey: Data], holdingStoreOf heldValue: Data) {
        base = InMemoryCredentialVault(records: records)
        self.heldValue = heldValue
    }

    func store(_ secret: Data, for key: CredentialRecordKey) async throws {
        if secret == heldValue, !released {
            await withCheckedContinuation { continuation in
                heldStore = continuation
                heldWaiters.forEach { $0.resume() }
                heldWaiters.removeAll()
            }
        }
        try await base.store(secret, for: key)
    }

    func load(_ key: CredentialRecordKey) async throws -> Data? { try await base.load(key) }
    func remove(_ key: CredentialRecordKey) async throws { try await base.remove(key) }
    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) async throws -> [Data?] {
        try await base.loadOrCreate(keys, create: create)
    }

    func waitUntilStoreIsHeld() async {
        guard heldStore == nil else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func releaseHeldStore() {
        released = true
        heldStore?.resume()
        heldStore = nil
    }
}

/// Polls an async condition until it holds or a bounded deadline passes.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return try await condition()
}
