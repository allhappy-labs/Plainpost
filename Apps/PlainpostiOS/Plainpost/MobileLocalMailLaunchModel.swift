import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostIOSRuntime
import PlainpostNodeTransport
import PlainpostNodeMailMode
import PlainpostSecrets
import PlainpostUI

enum MobileMailRoute {
    case localSetup
    /// One runtime for every account on the device, Direct or mirrored from a Sync Node.
    case allDirect
    case node(any PlainpostMailAuthority)
    case nodeUnavailable(AccountID)
}

struct MobileLocalMailAccountChoice: Identifiable {
    let id: AccountID
    let title: String
    /// The account's address, the switcher's label while it's selected.
    var email: String?
    /// The account itself, for the Settings account rows.
    var account: Account?
    /// Its mail comes from a Sync Node.
    var viaSyncNode = false
}

enum MobileLocalAccountSwitchPolicy {
    static func isBlocked(hasUnsavedComposer: Bool, isSendPending: Bool) -> Bool {
        hasUnsavedComposer || isSendPending
    }
}

/// Resolves the selected provider account from the device's durable source
/// catalog. Central configuration is only consulted by the optional sign-in
/// flow, never by this local launch path.
@MainActor
final class MobileLocalMailLaunchModel {
    let databaseURL: URL
    private let credentials: any CredentialVault
    private let nodeAuthority: @MainActor (AccountID) -> (any PlainpostMailAuthority)?
    private var preparedNode: (source: AccountMailSource, authority: any PlainpostMailAuthority, readOnly: Bool)?
    /// When the read-only Node session's offline lease ends, if it is read-only.
    private(set) var selectedNodeLeaseExpiry: Date?
    /// The device's Sync Node session, when it has one: the device-wide runtime mirrors every
    /// Sync Node account through it.
    var nodeBroker: NodeSessionBroker?
    private var deviceNodeMail: DeviceNodeMailBridge?

    var selectedNodeIsReadOnly: Bool { preparedNode?.readOnly ?? false }

    init(
        databaseURL: URL = IOSLocalDatabaseProtection.databaseURL(
            in: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("Plainpost", isDirectory: true)
        ),
        credentials: any CredentialVault = IOSDeviceCredentialVault(),
        nodeAuthority: @escaping @MainActor (AccountID) -> (any PlainpostMailAuthority)? = { _ in nil }
    ) {
        self.databaseURL = databaseURL
        self.credentials = credentials
        self.nodeAuthority = nodeAuthority
    }

    func route(for accountID: AccountID?) throws -> MobileMailRoute {
        guard let accountID else { return .localSetup }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        guard store.accounts.contains(where: { $0.id == accountID }) else {
            throw PlainpostError.permissionDenied("Selected mail account is unavailable.")
        }
        let source = try store.mailSource(accountID: accountID)
        switch source.kind {
        case .direct:
            // Every account shares one device-wide runtime.
            try store.requireDirectMailSource(accountID: accountID)
            return .allDirect
        case .nodeBacked where source.mode == .node && nodeBroker != nil:
            // The device mirrors its Sync Node accounts into the same runtime.
            return .allDirect
        case .nodeBacked:
            guard source.mode == .node,
                  let authority = preparedNode?.source == source ? preparedNode?.authority : nodeAuthority(accountID),
                  let scopedAccount = (authority as? PlainpostNodeMailAuthority)?.mailAccount,
                  authority.accountID == accountID,
                  (try? NodeSyncCodec.encodeLogicalMailboxID(scopedAccount.logicalMailboxID)) == source.logicalMailboxID,
                  scopedAccount.providerIdentity == source.providerIdentity else {
                return .nodeUnavailable(accountID)
            }
            return .node(authority)
        }
    }

    /// Restores a cataloged Node account through the process broker. A failed
    /// preparation leaves this account unavailable and never opens Direct I/O.
    func prepareSelectedNodeAuthority(
        broker: NodeSessionBroker,
        credentials: AccountCredentialStore
    ) async throws {
        preparedNode = nil
        selectedNodeLeaseExpiry = nil
        guard let accountID = try selectedAccountID(),
              let source = try catalogSource(accountID),
              source.kind == .nodeBacked, source.mode == .node,
              let sourceNodeID = source.nodeID,
              let mailboxID = source.logicalMailboxID,
              let providerIdentity = source.providerIdentity else { return }
        let session = try await broker.nodeClient()
        guard session.nodeID == sourceNodeID else { throw NodeSessionBrokerError.unavailable }
        let catalog = try await NodeMailAccountCatalog.load(session.client)
        guard let mailAccount = catalog.accounts.first(where: {
            (try? NodeSyncCodec.encodeLogicalMailboxID($0.logicalMailboxID)) == mailboxID
                && $0.providerIdentity == providerIdentity
        }),
              let record = try credentials.loadSession(), record.state == .active,
              let plainpostAccountID = record.credentials?.accountID,
              try selectedAccountID() == accountID,
              try catalogSource(accountID) == source else {
            throw NodeSessionBrokerError.unavailable
        }
        let journal = MobileNodeSendJournal(
            databaseURL: databaseURL, accountID: accountID,
            plainpostAccountID: plainpostAccountID, source: source
        )
        let access = try await broker.currentAdmission()
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: session.client, accountID: accountID, mailAccount: mailAccount,
            multiAccount: catalog.multiAccount,
            access: access == .readWrite ? .authorized : .cachedReadOnly,
            nodeSendJournal: journal
        )
        guard try selectedAccountID() == accountID,
              try catalogSource(accountID) == source else { throw NodeSessionBrokerError.unavailable }
        preparedNode = (source, authority, access != .readWrite)
        if case let .readOnly(expiresAt) = access { selectedNodeLeaseExpiry = expiresAt }
    }

    func selectedAccountID() throws -> AccountID? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        let accounts = store.accounts
        if let saved = UserDefaults.standard.string(forKey: "plainpost.ios.selected-provider-account"),
           let account = accounts.first(where: { $0.id.rawValue == saved }) { return account.id }
        let ordered = accounts.sorted { $0.id.rawValue < $1.id.rawValue }
        if let direct = ordered.first(where: { (try? store.requireDirectMailSource(accountID: $0.id)) != nil }) {
            return direct.id
        }
        return ordered.first?.id
    }

    func accountChoices() throws -> [MobileLocalMailAccountChoice] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        return store.accounts.sorted { $0.id.rawValue < $1.id.rawValue }.compactMap { account in
            guard let source = try? store.mailSource(accountID: account.id) else { return nil }
            let sourceLabel: String
            switch source.kind {
            case .direct: sourceLabel = "Direct"
            case .nodeBacked: sourceLabel = "Sync Node"
            }
            return MobileLocalMailAccountChoice(
                id: account.id,
                title: "\(account.displayName) (\(account.email.rawValue)) · \(sourceLabel)",
                email: account.email.rawValue,
                account: account,
                viaSyncNode: source.kind == .nodeBacked
            )
        }
    }

    func selectAccountID(_ accountID: AccountID) throws {
        guard try accountChoices().contains(where: { $0.id == accountID }) else {
            throw PlainpostError.permissionDenied("The selected mail account is unavailable.")
        }
        UserDefaults.standard.set(accountID.rawValue, forKey: "plainpost.ios.selected-provider-account")
    }

    /// The device-wide runtime: no selected account, every Direct account.
    func makeLocalRuntime(readOnly: Bool = false) throws -> PlainpostAppRuntime {
        try makeLocalRuntime(for: nil, readOnly: readOnly)
    }

    func makeLocalRuntime(for accountID: AccountID?, readOnly: Bool = false) throws -> PlainpostAppRuntime {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                selectedAccountID: accountID,
                runtimeDependencies: try directMailDependencies()
            ),
            accountAccess: readOnly ? .cachedReadOnly : .readWrite
        )
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        return runtime
    }

    /// Explicitly attaches the selected Direct account after proving the
    /// account, trusted Node, signed enrollment lease, and live provider
    /// catalog all agree. No local source changes before the final CAS.
    func attachSelectedDirectAccount(
        broker: NodeSessionBroker,
        accountCredentials: AccountCredentialStore,
        endpointStore: SyncNodeEndpointStore,
        manifest: SessionKeyManifestVerifier
    ) async throws -> PlainpostAppRuntime? {
        preparedNode = nil
        selectedNodeLeaseExpiry = nil
        guard let accountID = try selectedAccountID() else {
            throw NodeSessionBrokerError.unavailable
        }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw NodeSessionBrokerError.unavailable
        }
        let source = try store.mailSource(accountID: accountID)
        guard source.kind == .direct, try await broker.currentAdmission() == .readWrite else {
            throw NodeSessionBrokerError.notAdmitted
        }
        let context = try await VerifiedNodeAttachContextLoader.load(
            credentials: accountCredentials, endpointStore: endpointStore, manifest: manifest
        )
        let session = try await broker.nodeClient()
        guard session.nodeID == context.nodeID.rawValue else {
            throw NodeSessionBrokerError.unavailable
        }
        let catalog = try await NodeMailAccountCatalog.load(session.client)
        let matches = catalog.accounts.filter {
            $0.providerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == account.email.rawValue.lowercased()
        }
        guard matches.count == 1, let mailAccount = matches.first,
              try await broker.currentAdmission() == .readWrite,
              try selectedAccountID() == accountID,
              try catalogSource(accountID) == source else {
            throw NodeSessionBrokerError.unavailable
        }
        let proposal = try NodeAttachAdmission.propose(
            account: account, source: source, expectedGeneration: source.generation,
            plainpostAccountID: context.accountID, nodeID: context.nodeID,
            trustEpoch: context.trustEpoch, lease: context.lease,
            expectedAction: context.action, manifest: manifest, nodeAccount: mailAccount
        )
        let journal = MobileNodeSendJournal(
            databaseURL: databaseURL, accountID: accountID,
            plainpostAccountID: context.accountID, source: proposal
        )
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: session.client, accountID: accountID, mailAccount: mailAccount,
            multiAccount: catalog.multiAccount, access: .authorized,
            nodeSendJournal: journal
        )
        preparedNode = (proposal, authority, false)
        do {
            let currentContext = try await VerifiedNodeAttachContextLoader.load(
                credentials: accountCredentials, endpointStore: endpointStore, manifest: manifest
            )
            guard currentContext.accountID == context.accountID,
                  currentContext.nodeID == context.nodeID,
                  currentContext.trustEpoch == context.trustEpoch,
                  currentContext.action == context.action,
                  try await broker.currentAdmission() == .readWrite else {
                throw NodeSessionBrokerError.notAdmitted
            }
            return try attachSelectedNode(
                proposal, expectedGeneration: source.generation, authority: authority
            )
        } catch {
            preparedNode = nil
            selectedNodeLeaseExpiry = nil
            throw error
        }
    }

    /// Commits a proposal already checked against the verified Node session,
    /// signed lease, and live account catalog. The caller must publish the
    /// journal-backed scoped authority before calling this handoff. If the
    /// runtime cannot open after CAS, the persisted Node source remains
    /// unavailable; it must never silently resume Direct provider I/O.
    ///
    /// Returns nil with a Node session (`nodeBroker`): the device-wide runtime mirrors the
    /// account from then on, so no runtime of its own opens.
    func attachSelectedNode(
        _ proposal: AccountMailSource,
        expectedGeneration: Int64,
        authority: any PlainpostMailAuthority
    ) throws -> PlainpostAppRuntime? {
        let accountID = proposal.accountID
        guard try selectedAccountID() == accountID,
              expectedGeneration >= 0, expectedGeneration < Int64.max,
              proposal.kind == .nodeBacked, proposal.mode == .node,
              proposal.generation == expectedGeneration + 1,
              authority.accountID == accountID,
              let scopedAccount = (authority as? PlainpostNodeMailAuthority)?.mailAccount,
              (try? NodeSyncCodec.encodeLogicalMailboxID(scopedAccount.logicalMailboxID)) == proposal.logicalMailboxID,
              scopedAccount.providerIdentity == proposal.providerIdentity,
              let published = preparedNode?.source == proposal
                ? preparedNode?.authority : nodeAuthority(accountID),
              (published as AnyObject) === (authority as AnyObject) else {
            throw PlainpostError.permissionDenied("Selected Sync Node account or authority changed.")
        }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        guard let account = store.accounts.first(where: { $0.id == accountID }),
              account.email.rawValue.lowercased() == proposal.providerIdentity?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw PlainpostError.permissionDenied("Selected provider account changed.")
        }
        try store.requireDirectMailSource(accountID: accountID)
        let current = try store.mailSource(accountID: accountID)
        guard current.kind == .direct, current.generation == expectedGeneration,
              let nodeID = proposal.nodeID,
              let mailboxID = proposal.logicalMailboxID,
              let providerIdentity = proposal.providerIdentity,
              current.nodeBacked(nodeID: nodeID, logicalMailboxID: mailboxID,
                                 providerIdentity: providerIdentity) == proposal else {
            throw PlainpostError.permissionDenied("Selected mail source changed.")
        }
        try store.replaceMailSource(proposal, expectedGeneration: expectedGeneration)
        if nodeBroker != nil { return nil }
        return try makeNodeRuntime(for: accountID, authority: authority, readOnly: false)
    }

    func makeNodeRuntime(
        for accountID: AccountID,
        authority: any PlainpostMailAuthority,
        readOnly: Bool
    ) throws -> PlainpostAppRuntime {
        guard authority.accountID == accountID else {
            throw PlainpostError.permissionDenied("Selected Sync Node authority belongs to another account.")
        }
        // Central-connected accounts created before the local source catalog
        // have no safe Node ID to import here. Preserve their existing runtime
        // until an explicit source transition registers the account.
        guard let selectedNodeSource = try catalogSource(accountID) else {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PLAINPOST_APPROVAL_QUEUE_UI_ACCEPTANCE"]
                .flatMap(UUID.init(uuidString:)) != nil {
                return try PlainpostAppRuntime(
                    configuration: PlainpostAppRuntimeConfiguration(
                        databaseURL: databaseURL, mailAuthority: authority
                    ),
                    accountAccess: readOnly ? .cachedReadOnly : .readWrite
                )
            }
            #endif
            return try PlainpostAppRuntime(
                configuration: PlainpostAppRuntimeConfiguration(mailAuthority: authority),
                accountAccess: readOnly ? .cachedReadOnly : .readWrite
            )
        }
        guard selectedNodeSource.kind == .nodeBacked,
              selectedNodeSource.mode == .node else {
            throw PlainpostError.permissionDenied("Selected Sync Node source is unavailable.")
        }
        guard case .node(let currentAuthority) = try route(for: accountID),
              (currentAuthority as AnyObject) === (authority as AnyObject) else {
            throw PlainpostError.permissionDenied("Selected Sync Node account or authority changed.")
        }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL,
                selectedAccountID: accountID,
                mailAuthority: authority,
                selectedNodeSource: selectedNodeSource
            ),
            accountAccess: readOnly ? .cachedReadOnly : .readWrite
        )
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        return runtime
    }

    private func catalogSource(_ accountID: AccountID) throws -> AccountMailSource? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        guard store.accounts.contains(where: { $0.id == accountID }) else { return nil }
        return try store.mailSource(accountID: accountID)
    }

    private func directMailDependencies() throws -> IOSLocalMailRuntimeDependencies {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["PLAINPOST_STANDALONE_MAIL_E2E"] == "1" {
            guard let imapText = environment["PLAINPOST_MAIL_FIXTURE_IMAP_PORT"],
                  let imapPort = UInt16(imapText),
                  let smtpText = environment["PLAINPOST_MAIL_FIXTURE_SMTP_PORT"],
                  let smtpPort = Int(smtpText),
                  let imapTextAnchor = environment["PLAINPOST_MAIL_FIXTURE_IMAP_ANCHOR"],
                  let imapAnchor = Data(base64Encoded: imapTextAnchor),
                  let smtpTextAnchor = environment["PLAINPOST_MAIL_FIXTURE_SMTP_ANCHOR"],
                  let smtpAnchor = Data(base64Encoded: smtpTextAnchor) else {
                throw PlainpostError.permissionDenied("Incomplete secure mail fixture configuration.")
            }
            return IOSLocalMailRuntimeDependencies(
                credentials: credentials,
                googleClient: GoogleOAuthPublicClient.resolve(from: .main),
                microsoftClient: MicrosoftOAuthPublicClient.resolve(from: .main),
                imapClientFactory: { _, _ in
                    SecureIMAPClient(host: "127.0.0.1", port: imapPort,
                                     certificateValidation: .testAnchor(imapAnchor))
                },
                smtpClientFactory: { _, _ in
                    SecureSMTPClient(host: "127.0.0.1", port: smtpPort,
                                     certificateValidation: .testAnchor(smtpAnchor))
                }
            )
        }
        #endif
        return IOSLocalMailRuntimeDependencies(
            credentials: credentials, googleClient: GoogleOAuthPublicClient.resolve(from: .main),
            microsoftClient: MicrosoftOAuthPublicClient.resolve(from: .main),
            deviceNodeMail: try nodeMail())
    }

    /// Adds the Sync Node's accounts to the device's catalog. Without a Node session it
    /// does nothing and returns false.
    func addSyncNodeAccounts() async -> Bool {
        guard let bridge = try? nodeMail() else { return false }
        await bridge.addSyncNodeAccounts()
        return true
    }

    /// One bridge for the process: runtimes come and go, the mirror and its journal don't.
    private func nodeMail() throws -> DeviceNodeMailBridge? {
        if let deviceNodeMail { return deviceNodeMail }
        guard let nodeBroker else { return nil }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        // While its Node is away, an account whose sign-in is on the phone syncs from here.
        let directMail = IOSLocalMailRuntimeDependencies(
            credentials: credentials, googleClient: GoogleOAuthPublicClient.resolve(from: .main),
            microsoftClient: MicrosoftOAuthPublicClient.resolve(from: .main)
        ).makeDeviceDirectMail(store: store)
        let bridge = DeviceNodeMailBridge(
            store: store, broker: nodeBroker,
            direct: DeviceDirectMailDispatcher(store: store, actions: directMail.actions, delivery: directMail.delivery),
            mayFallBack: directMail.hasProviderSignIn
        )
        deviceNodeMail = bridge
        return bridge
    }
}
