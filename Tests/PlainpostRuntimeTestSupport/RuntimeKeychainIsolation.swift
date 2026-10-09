import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostUI
import PlainpostSecrets
import PlainpostServiceIPC

public enum RuntimeForegroundOperationKind: String, Equatable, Sendable {
    case inboxSync
    case historicalSync
    case ai
    case translateMessage
    case approveSend
    case denySend
    case accountAdd
    case accountTest
    case replaceAccountCredentials
    case googleAccountAdd
    case replaceGoogleAccountCredential
    case deleteAccount
    case deliverDirectDraft
    case deliverBrowserReply
    case archive
    case delete
    case markRead
    case markUnread
    case flag
    case unflag
    case move
    case addLabel
    case removeLabel
    case labelCommand
}

public actor RuntimeServiceClientFake: PlainpostServiceClientProtocol {
    public struct Snapshot: Equatable, Sendable {
        public let statusCallCount: Int
        public let unlockReasons: [String]
        public let lockCallCount: Int
        public let foregroundOperationKinds: [RuntimeForegroundOperationKind]
    }

    private var availability: PlainpostVaultStatus.Availability
    private var nextError: PlainpostServiceClientError?
    private var nextOperationFailure:
        (kind: RuntimeForegroundOperationKind, error: PlainpostServiceClientError)?
    private var statusCallCount = 0
    private var unlockReasons: [String] = []
    private var lockCallCount = 0
    private var foregroundOperationKinds: [RuntimeForegroundOperationKind] = []

    public init(
        availability: PlainpostVaultStatus.Availability = .unlocked
    ) {
        self.availability = availability
    }

    public func status() throws -> PlainpostVaultStatus {
        statusCallCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        return PlainpostVaultStatus(
            availability: availability,
            matchingKeyItemCount: availability == .keyMissing ? 0 : 1
        )
    }

    public func unlock(reason: String) throws {
        unlockReasons.append(reason)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        availability = .unlocked
    }

    public func lock() throws {
        lockCallCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        availability = .locked
    }

    public func perform(_ operation: PlainpostForegroundOperation) throws
        -> PlainpostForegroundOperationResult
    {
        let kind = Self.kind(operation)
        foregroundOperationKinds.append(kind)
        if let nextOperationFailure, nextOperationFailure.kind == kind {
            self.nextOperationFailure = nil
            throw nextOperationFailure.error
        }
        switch operation {
        case .inboxSync(let input): return .inboxSync(Self.syncResult(input))
        case .historicalSync(let input): return .historicalSync(Self.syncResult(input))
        case .ai(let input): return .ai(Self.aiResult(input))
        case .translateMessage(let input): return .translateMessage(Self.aiResult(input))
        case .approveSend: return .approveSend
        case .denySend: return .denySend
        case .accountAdd(let input):
            return .accountAdd(
                PlainpostAccountSetupSemanticResult(
                    accountID: "acc-runtime-service-fake", email: input.email, isIMAPVerified: true,
                    isSMTPVerified: true, syncedMessageCount: 0))
        case .accountTest:
            return .accountTest(
                PlainpostAccountTestSemanticResult(isIMAPVerified: true, isSMTPVerified: true))
        case .replaceAccountCredentials: return .replaceAccountCredentials
        case .googleAccountAdd(let input):
            return .googleAccountAdd(
                PlainpostAccountSetupSemanticResult(
                    accountID: "acc-runtime-service-fake", email: input.email, isIMAPVerified: true,
                    isSMTPVerified: true, syncedMessageCount: 0))
        case .replaceGoogleAccountCredential: return .replaceGoogleAccountCredential
        case .deleteAccount: return .deleteAccount
        case .deliverDirectDraft(let input):
            return .deliverDirectDraft(
                PlainpostDirectDraftDeliverySemanticResult(
                    messageID: "sent-\(input.draftID)", remoteSentCopyAppended: true))
        case .deliverBrowserReply:
            return .deliverBrowserReply(
                PlainpostBrowserReplyDeliverySemanticResult(
                    requestID: "request-1", jobID: "job-1", state: "sent"))
        case .archive(let input): return .archive(Self.mailResult(input, mailboxPath: "Archive"))
        case .delete(let input): return .delete(Self.mailResult(input, isDeleted: true))
        case .markRead(let input): return .markRead(Self.mailResult(input, seen: true))
        case .markUnread(let input): return .markUnread(Self.mailResult(input, seen: false))
        case .flag(let input): return .flag(Self.mailResult(input))
        case .unflag(let input): return .unflag(Self.mailResult(input))
        case .move(let input): return .move(Self.mailResult(input, mailboxPath: input.archiveMailbox))
        case .addLabel: return .addLabel
        case .removeLabel: return .removeLabel
        case .labelCommand: return .labelCommand
        }
    }

    public func setAvailability(_ availability: PlainpostVaultStatus.Availability) {
        self.availability = availability
    }

    public func failNextCall(with error: PlainpostServiceClientError) {
        nextError = error
    }

    public func failNextOperation(
        _ kind: RuntimeForegroundOperationKind,
        with error: PlainpostServiceClientError
    ) {
        nextOperationFailure = (kind, error)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            statusCallCount: statusCallCount, unlockReasons: unlockReasons,
            lockCallCount: lockCallCount, foregroundOperationKinds: foregroundOperationKinds)
    }

    private static func syncResult(_ input: PlainpostInboxSyncInput) -> PlainpostInboxSyncResult {
        PlainpostInboxSyncResult(
            accountID: input.accountID, syncedMessageCount: 0, jobID: "runtime-service-fake-sync")
    }

    private static func aiResult(_ input: PlainpostAIOperationInput) -> PlainpostAIOperationResult {
        PlainpostAIOperationResult(
            operation: input.operation, recordID: input.recordID,
            artifactID: "runtime-service-fake-artifact", jobID: "runtime-service-fake-ai")
    }

    private static func mailResult(
        _ input: PlainpostMailActionPayload, seen: Bool? = nil, mailboxPath: String? = nil,
        isDeleted: Bool = false
    ) -> PlainpostMailActionSemanticResult {
        PlainpostMailActionSemanticResult(
            messageID: input.messageID, seen: seen, mailboxPath: mailboxPath, isDeleted: isDeleted)
    }

    private static func kind(_ operation: PlainpostForegroundOperation)
        -> RuntimeForegroundOperationKind
    {
        switch operation {
        case .inboxSync: .inboxSync
        case .historicalSync: .historicalSync
        case .ai: .ai
        case .translateMessage: .translateMessage
        case .approveSend: .approveSend
        case .denySend: .denySend
        case .accountAdd: .accountAdd
        case .accountTest: .accountTest
        case .replaceAccountCredentials: .replaceAccountCredentials
        case .googleAccountAdd: .googleAccountAdd
        case .replaceGoogleAccountCredential: .replaceGoogleAccountCredential
        case .deleteAccount: .deleteAccount
        case .deliverDirectDraft: .deliverDirectDraft
        case .deliverBrowserReply: .deliverBrowserReply
        case .archive: .archive
        case .delete: .delete
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .flag: .flag
        case .unflag: .unflag
        case .move: .move
        case .addLabel: .addLabel
        case .removeLabel: .removeLabel
        case .labelCommand: .labelCommand
        }
    }
}

/// Test-only secret fixtures stay outside production UI/App targets. Production
/// code sees only service-client and non-secret runtime dependency protocols.
#if DEBUG
public final class RuntimeKeychainIsolation: @unchecked Sendable {
    public let configuration: PlainpostAppRuntimeConfiguration
    public let credentials: InMemoryCredentialVault
    public let serviceClient: RuntimeServiceClientFake
    public let runtimeDependencies: InMemoryAppRuntimeDependencies

    public init(
        testCase: XCTestCase,
        databaseURL: URL,
        keychainService: String
    ) {
        let identifier = UUID().uuidString
        let credentials = InMemoryCredentialVault()
        let serviceClient = RuntimeServiceClientFake()
        let runtimeDependencies = InMemoryAppRuntimeDependencies(
            credentials: credentials
        )
        self.credentials = credentials
        self.serviceClient = serviceClient
        self.runtimeDependencies = runtimeDependencies
        configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: databaseURL,
            keychainService: keychainService,
            serviceClient: serviceClient
        ).withRuntimeDependencies(runtimeDependencies)
        _ = testCase
    }

    public func attachingRuntimeDependencies(
        to configuration: PlainpostAppRuntimeConfiguration
    ) -> PlainpostAppRuntimeConfiguration {
        configuration.withRuntimeDependencies(runtimeDependencies)
    }

    public func cleanup() throws {}
}
#endif

public final class InMemoryAppRuntimeDependencies:
    PlainpostAppRuntimeDependencyProviding,
    @unchecked Sendable
{
    private let credentials: InMemoryCredentialVault
    private let constructionLock = NSLock()
    private var constructionCalls = 0
    public let deviceNodeMail: (any DeviceNodeMailBridging)?

    public var constructionCallCount: Int {
        constructionLock.withLock { constructionCalls }
    }

    public init(credentials: InMemoryCredentialVault, deviceNodeMail: (any DeviceNodeMailBridging)? = nil) {
        self.credentials = credentials
        self.deviceNodeMail = deviceNodeMail
    }

    public func makeDirectComposerSender(
        store: SQLiteMailStore
    ) throws -> any DirectComposerSending {
        recordConstruction()
        return InMemoryRuntimeDirectComposerSender(
            store: store,
            credentials: credentials
        )
    }

    public func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>
    ) -> LocalOperationRuntime {
        recordConstruction()
        return LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: allowedJobKinds
        )
    }

    public func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>,
        selectedDirectAccountID: AccountID?,
        expectedDirectSourceGeneration: Int64?
    ) -> LocalOperationRuntime {
        recordConstruction()
        return LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: allowedJobKinds,
            selectedDirectAccountID: selectedDirectAccountID,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration,
            requireSelectedDirectClaimScope: true
        )
    }

    public func makeAccountSetupHandler(
        store: SQLiteMailStore,
        inboxSyncOrchestrator: any AccountInboxSyncOrchestrating
    ) -> any AccountSetupHandling {
        recordConstruction()
        return AccountSetupService(
            store: store,
            credentials: credentials,
            inboxSyncOrchestrator: inboxSyncOrchestrator,
            publishDirectMailSource: true
        )
    }

    public func saveAccountCredentials(
        accountID: AccountID,
        imapPassword: String,
        smtpPassword: String
    ) async throws {
        recordConstruction()
        try await credentials.store(
            Data(imapPassword.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(accountID.rawValue):imap-password"
            )
        )
        try await credentials.store(
            Data(smtpPassword.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(accountID.rawValue):smtp-password"
            )
        )
    }

    public func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling
    ) -> any InboxMailActionHandling {
        recordConstruction()
        return InMemoryRuntimeInboxMailActionHandler(
            store: store,
            credentials: credentials,
            mailboxFlagScheduler: mailboxFlagScheduler
        )
    }

    private func recordConstruction() {
        constructionLock.withLock {
            constructionCalls += 1
        }
    }
}

private final class InMemoryRuntimeDirectComposerSender:
    DirectComposerSending,
    @unchecked Sendable
{
    private let deliveryService: LocalDraftDeliveryService
    private let actor = Actor(
        id: "local-user",
        kind: .user,
        displayName: "Local User",
        permissions: .guiUser
    )

    init(
        store: SQLiteMailStore,
        credentials: InMemoryCredentialVault
    ) {
        self.deliveryService = LocalDraftDeliveryService(
            store: store,
            credentials: credentials
        )
    }

    func send(draft: Draft) async throws -> DirectComposerSendResult {
        let result = try await deliveryService.deliver(
            draftID: draft.id,
            expectedHash: draft.contentHash,
            actor: actor
        )
        return DirectComposerSendResult(
            messageID: result.messageID,
            remoteSentCopyAppended: result.remoteSentCopyAppended
        )
    }
}

private final class InMemoryRuntimeInboxMailActionHandler:
    InboxMailActionHandling,
    @unchecked Sendable
{
    private let store: SQLiteMailStore
    private let credentials: InMemoryCredentialVault
    private let mailboxFlagScheduler: any MailboxFlagScheduling

    init(
        store: SQLiteMailStore,
        credentials: InMemoryCredentialVault,
        mailboxFlagScheduler: any MailboxFlagScheduling
    ) {
        self.store = store
        self.credentials = credentials
        self.mailboxFlagScheduler = mailboxFlagScheduler
    }

    func perform(
        _ action: InboxMailAction,
        messageID: MessageID
    ) async throws -> InboxMailActionResult {
        if action == .markRead || action == .markUnread {
            return try await InboxMailActionService(
                store: store,
                mailboxFlagScheduler: mailboxFlagScheduler
            ).perform(action, messageID: messageID)
        }

        let store = self.store
        let credentials = self.credentials
        let mailboxFlagScheduler = self.mailboxFlagScheduler
        return try await Task.detached(priority: .utility) {
            guard let account = store.accounts.first else {
                return try await InboxMailActionService(
                    store: store,
                    mailboxFlagScheduler: mailboxFlagScheduler
                ).perform(action, messageID: messageID)
            }
            guard let passwordData = try await credentials.load(
                CredentialRecordKey(
                    rawValue: "account:\(account.id.rawValue):imap-password"
                )
            ) else {
                throw PlainpostError.validationFailed(
                    "IMAP credentials are not available."
                )
            }
            guard let password = String(
                data: passwordData,
                encoding: .utf8
            ) else {
                throw CredentialVaultError.ciphertextInvalid
            }

            let imapClient = MailTransportClientFactory.imapClient(
                host: account.imapHost,
                port: account.imapPort
            )
            try await imapClient.login(
                username: account.username,
                password: password
            )
            _ = try await imapClient.selectMailbox("INBOX")
            return try await InboxMailActionService(
                store: store,
                imapClient: imapClient,
                mailboxFlagScheduler: mailboxFlagScheduler
            ).perform(action, messageID: messageID)
        }.value
    }
}
