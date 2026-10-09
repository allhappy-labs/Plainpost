import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostSecrets

/// Owns one long-lived INBOX watcher per enabled account. Watchers only enqueue
/// durable reconciliation jobs through an injected signal; all mailbox mutation
/// remains outside this supervisor.
public actor IMAPIdleSupervisor {
    public typealias Signal = @Sendable (AccountID) async throws -> Void
    typealias ClientFactory = @Sendable (String, UInt16) -> any IMAPClientProtocol
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Watcher: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }
    private let store: SQLiteMailStore
    private let credentialResolver: MailCredentialResolver
    private let signal: Signal
    private let clientFactory: ClientFactory
    private let sleep: Sleep
    private var watchers: [AccountID: Watcher] = [:]

    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        credentialResolver: MailCredentialResolver? = nil,
        signal: @escaping Signal
    ) {
        self.init(
            store: store,
            credentials: credentials,
            credentialResolver: credentialResolver,
            signal: signal,
            clientFactory: { host, port in
                MailTransportClientFactory.imapClient(host: host, port: port)
            },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }

    init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        credentialResolver: MailCredentialResolver? = nil,
        signal: @escaping Signal,
        clientFactory: @escaping ClientFactory,
        sleep: @escaping Sleep
    ) {
        self.store = store
        self.credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: credentials)
        self.signal = signal
        self.clientFactory = clientFactory
        self.sleep = sleep
    }

    /// Watches Direct and fallback accounts only. A flip to Node mode posts an
    /// `.accounts` change, and the resulting reconcile cancels the watcher now.
    public func reconcileAccounts() async {
        let enabledAccounts = store.directSyncAccounts.filter {
            (try? store.syncPreferences(accountID: $0.id).realTimeMonitoringEnabled) == true
        }
        let enabledIDs = Set(enabledAccounts.map(\.id))
        var removedTasks: [Task<Void, Never>] = []
        for (accountID, watcher) in watchers where !enabledIDs.contains(accountID) {
            watcher.task.cancel()
            watchers.removeValue(forKey: accountID)
            removedTasks.append(watcher.task)
        }
        for task in removedTasks { await task.value }

        for account in enabledAccounts where watchers[account.id] == nil {
            let token = UUID()
            let task = Task { [weak self, store, credentialResolver, signal, clientFactory, sleep] in
                await Self.watch(
                    accountID: account.id,
                    store: store,
                    credentialResolver: credentialResolver,
                    signal: signal,
                    clientFactory: clientFactory,
                    sleep: sleep
                )
                await self?.watcherFinished(accountID: account.id, token: token)
            }
            watchers[account.id] = Watcher(token: token, task: task)
        }
    }

    public func stop() async {
        let tasks = watchers.values.map(\.task)
        watchers.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    private static func watch(
        accountID: AccountID,
        store: SQLiteMailStore,
        credentialResolver: MailCredentialResolver,
        signal: @escaping Signal,
        clientFactory: @escaping ClientFactory,
        sleep: @escaping Sleep
    ) async {
        var failedAttempts = 0
        while !Task.isCancelled {
            // Re-checked every pass, so a flip to Node mode also ends the
            // watcher within one IDLE renewal without a reconcile. A source
            // that cannot be read is not a flip: back off and ask again.
            let runsDirectSync: Bool
            do {
                runsDirectSync = try store.mailSource(accountID: accountID).runsDirectSync
            } catch {
                failedAttempts += 1
                try? await sleep(.seconds(Self.backoffSeconds(failedAttempts: failedAttempts)))
                continue
            }
            guard let account = store.accounts.first(where: { $0.id == accountID }),
                  runsDirectSync,
                  (try? store.syncPreferences(accountID: accountID).realTimeMonitoringEnabled) == true else { return }
            let slot = IdleClientSlot()
            do {
                // Authentication is the first step on each fresh connection,
                // so the resolver's single OAuth retry never repeats IDLE work.
                let outcome = try await credentialResolver.withIMAPAuthentication(for: account) { authentication in
                    let client = clientFactory(account.imapHost, account.imapPort)
                    await slot.replace(with: client)
                    try await client.authenticate(username: account.username, authentication: authentication)
                    _ = try await client.selectMailbox("INBOX")
                    return try await client.idle(maxDuration: 25 * 60)
                }
                await slot.disconnect()
                switch outcome {
                case .mailboxChanged:
                    try await signal(accountID)
                    failedAttempts = 0
                case .renewalDue:
                    failedAttempts = 0
                case .unsupported:
                    try await signal(accountID)
                    failedAttempts = 0
                    try await sleep(.seconds(60))
                case .serverClosing:
                    throw IMAPClientError.connectionFailed
                }
            } catch is CancellationError {
                await slot.disconnect()
                return
            } catch CredentialVaultError.locked,
                    MailCredentialError.unavailable,
                    MailCredentialError.reauthorizationRequired {
                // Wait for an unlock, a stored credential or a reauthorization.
                await slot.disconnect()
                try? await sleep(.seconds(30))
            } catch is CredentialVaultError {
                await slot.disconnect()
                return
            } catch MailCredentialError.oauthNotConfigured {
                await slot.disconnect()
                return
            } catch {
                await slot.disconnect()
                failedAttempts += 1
                try? await sleep(.seconds(Self.backoffSeconds(failedAttempts: failedAttempts)))
            }
        }
    }

    private static func backoffSeconds(failedAttempts: Int) -> Double {
        let maximum = min(60.0, pow(2, Double(min(failedAttempts, 6))))
        return Double.random(in: 0.5...max(0.5, maximum))
    }

    var watchedAccountIDs: [AccountID] {
        Array(watchers.keys)
    }

    private func watcherFinished(accountID: AccountID, token: UUID) {
        guard watchers[accountID]?.token == token else { return }
        watchers.removeValue(forKey: accountID)
    }
}

/// The connection a watcher currently owns, so cancellation and retries
/// always disconnect it exactly once.
private final class IdleClientSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any IMAPClientProtocol)?

    func replace(with next: any IMAPClientProtocol) async {
        let previous = lock.withLock { () -> (any IMAPClientProtocol)? in
            let previous = client
            client = next
            return previous
        }
        await previous?.disconnect()
    }

    func disconnect() async {
        let current = lock.withLock { () -> (any IMAPClientProtocol)? in
            let current = client
            client = nil
            return current
        }
        await current?.disconnect()
    }
}
