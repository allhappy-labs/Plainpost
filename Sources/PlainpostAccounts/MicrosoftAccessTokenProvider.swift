import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

/// Sole owner of Microsoft Exchange access tokens and refresh-token rotation.
public actor MicrosoftAccessTokenProvider {
    /// A cached token is refreshed once fewer than this many seconds remain.
    static let refreshMargin: TimeInterval = 120
    /// A caller whose refresh was overtaken by a newer grant re-reads the
    /// current generation at most this many times.
    private static let maximumGenerationRetries = 3

    /// An access token together with the grant generation that issued it.
    struct Lease: Sendable {
        let accessToken: String
        let generation: UInt64
    }

    private struct CachedToken {
        let value: String
        let expiresAt: Date
        let generation: UInt64
    }

    private struct Flight {
        let id: UUID
        let generation: UInt64
        let task: Task<Lease, Error>
    }

    private let store: SQLiteMailStore
    private let credentials: any CredentialVault
    private let tokens: MicrosoftMailOAuthProvider?
    private let now: @Sendable () -> Date
    private var cache: [AccountID: CachedToken] = [:]
    private var inFlight: [AccountID: Flight] = [:]
    private var generations: [AccountID: UInt64] = [:]
    /// Bumped by every `installGrant`, before and after `apply`. A refresh
    /// reads it before it contacts Microsoft; a rotation that arrives after a
    /// newer grant was installed is dropped, because that grant's own refresh
    /// token is the live one. Unlike the generation it is not moved by
    /// `forget` or `forgetAll`, which must not cost a committed rotation.
    private var grantInstalls: [AccountID: UInt64] = [:]
    private var grantWriteHolders: Set<AccountID> = []
    private var grantWriteWaiters: [AccountID: [CheckedContinuation<Void, Never>]] = [:]
    /// Bumped by every `forgetAll`. `installGrant` reads it before and after
    /// `apply` runs; a change in between means a lockdown raced the install,
    /// and the grant's token must not seed the cache.
    private var lockdownEpoch: UInt64 = 0
    /// The account whose grant write the current task already holds, if any.
    /// `withGrantWrite` fails fast when it is asked to hold the same
    /// account's grant write again from within itself, instead of hanging:
    /// a closure that awaits back into a provider method for the account it
    /// is already installing or refreshing would otherwise wait forever
    /// behind its own hold, with nothing to release it.
    @TaskLocal private static var reentrantGrantWriteAccount: AccountID?

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        tokens: MicrosoftMailOAuthProvider?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.credentials = credentials
        self.tokens = tokens
        self.now = now
    }

    public func accessToken(for accountID: AccountID) async throws -> String {
        try await lease(for: accountID).accessToken
    }

    func lease(for accountID: AccountID) async throws -> Lease {
        var attempt = 0
        while true {
            let generation = generation(of: accountID)
            if let cached = cache[accountID], cached.generation == generation,
               cached.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
                return Lease(accessToken: cached.value, generation: generation)
            }
            let flight: Flight
            if let existing = inFlight[accountID], existing.generation == generation {
                flight = existing
            } else {
                guard try store.accountAuthentication(accountID: accountID).state == .ready else {
                    throw MailCredentialError.reauthorizationRequired
                }
                flight = Flight(
                    id: UUID(), generation: generation,
                    task: Task { try await self.refresh(accountID: accountID, generation: generation) })
                inFlight[accountID] = flight
            }
            do {
                let lease = try await flight.task.value
                clearFlight(flight, accountID: accountID)
                if lease.generation == self.generation(of: accountID) { return lease }
            } catch {
                clearFlight(flight, accountID: accountID)
                guard flight.generation != self.generation(of: accountID) else { throw error }
            }
            // A newer grant replaced the one this refresh used. Use the
            // current grant instead of the stale outcome.
            attempt += 1
            guard attempt < Self.maximumGenerationRetries else { throw MicrosoftOAuthError.unavailable }
        }
    }

    /// Drops the cached token only if it is still `rejectedAccessToken`, for
    /// example after the server answered `MailAuthenticationError.rejected`.
    /// A token installed after the rejected one was issued is kept.
    public func invalidate(accountID: AccountID, rejectedAccessToken: String) {
        if cache[accountID]?.value == rejectedAccessToken {
            cache[accountID] = nil
        }
    }

    /// Installs a freshly verified grant. `apply` writes the refresh token and
    /// account state while refresh outcomes for the account are held back;
    /// every refresh that started before `apply` returned is then stale. On
    /// success the grant's access token seeds the cache, unless a vault
    /// lockdown (`forgetAll`) ran while `apply` was in flight, in which case
    /// the account is left forgotten instead of reseeding a token that must
    /// not survive lockdown.
    public func installGrant(
        accessToken: String,
        expiresAt: Date,
        accountID: AccountID,
        apply: @Sendable () async throws -> Void
    ) async throws {
        try await withGrantWrite(accountID) {
            advanceGeneration(accountID)
            grantInstalls[accountID] = installCount(of: accountID) &+ 1
            let epochAtStart = lockdownEpoch
            try await apply()
            // Refreshes that began while `apply` ran may have read either record.
            let generation = advanceGeneration(accountID)
            grantInstalls[accountID] = installCount(of: accountID) &+ 1
            guard lockdownEpoch == epochAtStart else { return }
            cache[accountID] = CachedToken(value: accessToken, expiresAt: expiresAt, generation: generation)
        }
    }

    /// Forgets the account's cached token and makes every in-flight refresh
    /// stale, for example when the account is deleted.
    public func forget(accountID: AccountID) async {
        await withGrantWrite(accountID) {
            _ = advanceGeneration(accountID)
        }
    }

    /// Forgets every cached token and makes every in-flight refresh stale, for
    /// example at vault lockdown. Deliberately does not take the per-account
    /// grant-write lock, so it can never be blocked by (or deadlock with) an
    /// `installGrant` whose `apply` is in flight; `installGrant` instead
    /// checks `lockdownEpoch` before it seeds the cache.
    public func forgetAll() {
        lockdownEpoch &+= 1
        let accountIDs = Set(cache.keys).union(inFlight.keys).union(generations.keys)
        for accountID in accountIDs {
            advanceGeneration(accountID)
        }
    }

    /// Records that the mail server refused a refreshed token from
    /// `generation`. Returns false, without writing, when a newer grant has
    /// been installed since.
    func markReauthorizationRequired(accountID: AccountID, generation: UInt64) async throws -> Bool {
        try await withGrantWrite(accountID) {
            guard self.generation(of: accountID) == generation else { return false }
            try markReauthorizationRequiredLocked(accountID: accountID)
            return true
        }
    }

    /// Number of callers waiting to apply a grant write for the account.
    func pendingGrantWrites(for accountID: AccountID) -> Int {
        grantWriteWaiters[accountID]?.count ?? 0
    }

    private func refresh(accountID: AccountID, generation: UInt64) async throws -> Lease {
        guard let tokens else { throw MailCredentialError.oauthNotConfigured }
        guard let stored = try await credentials.load(MailCredentialKeys.microsoftRefreshToken(accountID)),
              let refreshToken = String(data: stored, encoding: .utf8), !refreshToken.isEmpty
        else { throw MailCredentialError.unavailable }

        // Read before the network call: `installGrant` bumps it around `apply`,
        // so any install that overlaps this refresh moves it.
        let installsAtStart = installCount(of: accountID)

        let access: MicrosoftAccessToken
        do {
            access = try await tokens.refreshExchangeToken(refreshToken: refreshToken)
        } catch MicrosoftOAuthError.invalidGrant, MicrosoftOAuthError.scopeMissing {
            // A reauthorization installed while this refresh was in flight
            // must not be overwritten by the old grant's refusal.
            let marked = try await withGrantWrite(accountID) { () throws -> Bool in
                guard self.generation(of: accountID) == generation else { return false }
                try markReauthorizationRequiredLocked(accountID: accountID)
                return true
            }
            throw marked ? MailCredentialError.reauthorizationRequired : MicrosoftOAuthError.unavailable
        } catch MicrosoftOAuthError.notConfigured {
            throw MailCredentialError.oauthNotConfigured
        }

        try await withGrantWrite(accountID) {
            // Microsoft can commit a rotation before the client sees it, so the
            // token this refresh started from is already dead. Persist the
            // rotation even when a lockdown or a forget moved the generation,
            // or the account is left with a dead record and only recovers
            // through a later `invalid_grant`. Two writers still win over it:
            // the compare-and-set on the record keeps a deleted account from
            // being resurrected, and an installed grant owns the record
            // outright, whatever token value it wrote.
            if let rotated = access.rotatedRefreshToken, Data(rotated.utf8) != stored,
               installCount(of: accountID) == installsAtStart,
               try await credentials.load(MailCredentialKeys.microsoftRefreshToken(accountID)) == stored {
                try await credentials.store(Data(rotated.utf8), for: MailCredentialKeys.microsoftRefreshToken(accountID))
            }
            // The access token is a different matter: a token from a grant
            // that lockdown, a forget or a newer install superseded must never
            // be cached. `forgetAll` does not wait for grant writes, so this
            // is read inside the hold.
            guard self.generation(of: accountID) == generation else { return }
            cache[accountID] = CachedToken(value: access.value, expiresAt: access.expiresAt, generation: generation)
        }
        return Lease(accessToken: access.value, generation: generation)
    }

    private func markReauthorizationRequiredLocked(accountID: AccountID) throws {
        cache[accountID] = nil
        try store.setAccountAuthentication(
            accountID: accountID, method: .microsoftOAuth, state: .reauthorizationRequired)
    }

    private func generation(of accountID: AccountID) -> UInt64 {
        generations[accountID, default: 0]
    }

    private func installCount(of accountID: AccountID) -> UInt64 {
        grantInstalls[accountID, default: 0]
    }

    @discardableResult
    private func advanceGeneration(_ accountID: AccountID) -> UInt64 {
        let next = generation(of: accountID) &+ 1
        generations[accountID] = next
        cache[accountID] = nil
        inFlight[accountID] = nil
        return next
    }

    private func clearFlight(_ flight: Flight, accountID: AccountID) {
        if inFlight[accountID]?.id == flight.id { inFlight[accountID] = nil }
    }

    /// Serializes grant installation and refresh outcomes for one account.
    private func withGrantWrite<T>(
        _ accountID: AccountID,
        _ body: () async throws -> T
    ) async rethrows -> T {
        if Self.reentrantGrantWriteAccount == accountID {
            preconditionFailure(
                "MicrosoftAccessTokenProvider.withGrantWrite(\(accountID.rawValue)) reentered from within "
                + "its own held grant write; this task would otherwise wait forever for itself to finish.")
        }
        while grantWriteHolders.contains(accountID) {
            await withCheckedContinuation { grantWriteWaiters[accountID, default: []].append($0) }
        }
        grantWriteHolders.insert(accountID)
        defer {
            grantWriteHolders.remove(accountID)
            if var waiters = grantWriteWaiters[accountID], !waiters.isEmpty {
                let next = waiters.removeFirst()
                grantWriteWaiters[accountID] = waiters.isEmpty ? nil : waiters
                next.resume()
            }
        }
        return try await Self.$reentrantGrantWriteAccount.withValue(accountID) {
            try await body()
        }
    }
}
