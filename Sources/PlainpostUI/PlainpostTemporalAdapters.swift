import Foundation
import PlainpostAI
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostOperationRuntime

final class LocalOperationAccountInboxSyncer: AccountInboxSyncOrchestrating, @unchecked Sendable {
    private let client: any PlainpostOperationClientProtocol
    private let notificationScheduler: any LocalNotificationScheduling
    private let didCompleteSync: @Sendable () async -> Void
    private let directSourceProvider: @Sendable () throws -> (AccountID, Int64)?
    /// The device-wide runtime's per-account generation: each account's sync carries its
    /// own Direct generation. When set, it replaces the single selected source.
    private let accountGenerationProvider: (@Sendable (Account) throws -> Int64?)?

    init(
        client: any PlainpostOperationClientProtocol,
        notificationScheduler: any LocalNotificationScheduling,
        didCompleteSync: @escaping @Sendable () async -> Void = {},
        directSourceProvider: @escaping @Sendable () throws -> (AccountID, Int64)? = { nil },
        accountGenerationProvider: (@Sendable (Account) throws -> Int64?)? = nil
    ) {
        self.client = client
        self.notificationScheduler = notificationScheduler
        self.didCompleteSync = didCompleteSync
        self.directSourceProvider = directSourceProvider
        self.accountGenerationProvider = accountGenerationProvider
    }

    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        // Generic/service clients retain their existing result semantics. The
        // concrete local client can distinguish executing from observing a job.
        var ownsTerminalEffects = !(client is LocalOperationClient)
        do {
            let directSource: (AccountID, Int64)?
            if let accountGenerationProvider {
                directSource = try accountGenerationProvider(account).map { (account.id, $0) }
            } else {
                directSource = try directSourceProvider()
            }
            if let directSource, directSource.0 != account.id {
                throw PlainpostError.permissionDenied("This sync requires the selected Direct account.")
            }
            let input: PlainpostInboxSyncInput
            switch reason {
            case .accountSetup:
                input = .init(
                    accountID: account.id, trigger: .accountSetup, scope: .recent,
                    expectedDirectSourceGeneration: directSource?.1
                )
            case .manual:
                input = .init(
                    accountID: account.id, trigger: .manual, scope: .recent,
                    expectedDirectSourceGeneration: directSource?.1
                )
            case .background:
                input = .init(
                    accountID: account.id, trigger: .realTimeSignal, scope: .incremental,
                    expectedDirectSourceGeneration: directSource?.1
                )
            }
            let result: PlainpostInboxSyncResult
            if let local = client as? LocalOperationClient {
                let outcome = await local.executeInboxSyncWithTerminalOwnership(input)
                ownsTerminalEffects = outcome.ownsTerminalEffects
                result = try outcome.result.get()
            } else {
                result = try await client.executeInboxSync(input)
            }
            if ownsTerminalEffects, reason != .accountSetup {
                try? await notificationScheduler.schedule(
                    .syncCompleted(account: account, newMessageCount: result.newlyDiscoveredMessageCount)
                )
            }
            let syncResult = IMAPSyncResult(
                syncedMessageCount: result.syncedMessageCount,
                newlyDiscoveredMessageCount: result.newlyDiscoveredMessageCount,
                source: result.source
            )
            if ownsTerminalEffects { await didCompleteSync() }
            return syncResult
        } catch {
            if ownsTerminalEffects, reason != .accountSetup {
                try? await notificationScheduler.schedule(.syncFailed(account: account))
            }
            throw error
        }
    }

    /// Kept at durable terminal completion, never at a foreground checkpoint.
    func didFinishForegroundOwnedSync(
        account: Account, result: Result<PlainpostInboxSyncResult, Error>
    ) async {
        switch result {
        case .success(let result):
            try? await notificationScheduler.schedule(
                .syncCompleted(account: account, newMessageCount: result.newlyDiscoveredMessageCount)
            )
            await didCompleteSync()
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            try? await notificationScheduler.schedule(.syncFailed(account: account))
        }
    }
}

/// Schedules background classification after cached mail changes without
/// turning an otherwise successful mail sync into an AI-provider failure.
actor SmartInboxSyncCompletionOrganizer {
    private let client: any PlainpostOperationClientProtocol
    private let selectedAIProviderID: @Sendable () -> String
    private let aiGenerationAvailable: @Sendable () -> Bool
    private let smartInboxEnabled: @Sendable () -> Bool
    private let scopeProvider: @Sendable () throws -> PlainpostSmartInboxRunScope
    private let directSourceProvider: @Sendable () throws -> (AccountID, Int64)?

    init(
        client: any PlainpostOperationClientProtocol,
        selectedAIProviderID: @escaping @Sendable () -> String,
        aiGenerationAvailable: @escaping @Sendable () -> Bool = { true },
        smartInboxEnabled: @escaping @Sendable () -> Bool = { true },
        scopeProvider: @escaping @Sendable () throws -> PlainpostSmartInboxRunScope = { .allAccounts },
        directSourceProvider: @escaping @Sendable () throws -> (AccountID, Int64)? = { nil }
    ) {
        self.client = client
        self.selectedAIProviderID = selectedAIProviderID
        self.aiGenerationAvailable = aiGenerationAvailable
        self.smartInboxEnabled = smartInboxEnabled
        self.scopeProvider = scopeProvider
        self.directSourceProvider = directSourceProvider
    }

    func requestIncrementalOrganization() async {
        guard aiGenerationAvailable(), smartInboxEnabled() else { return }
        let scope: PlainpostSmartInboxRunScope
        let directSource: (AccountID, Int64)?
        do {
            scope = try scopeProvider()
            directSource = try directSourceProvider()
        } catch {
            return
        }
        if let directSource, scope != .account(directSource.0) { return }
        let providerID = selectedAIProviderID()
        let classifierIdentity = SmartInboxClassifierIdentity.resolve(
            providerID: providerID,
            modelID: AIProviderSelection.classifierModelID(providerID: providerID)
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            accountID: directSource?.0,
            expectedDirectSourceGeneration: directSource?.1,
            providerID: providerID,
            modelID: classifierIdentity.modelID,
            smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                mode: .incremental, scope: scope, requestedLabelID: nil
            ),
            smartInboxClassifierIdentity: classifierIdentity
        )
        try? await client.enqueueIncrementalSmartInbox(input)
    }
}

final class LocalOperationThreadAIAssistantService: ThreadAIAssistantHandling, @unchecked Sendable {
    private let client: any PlainpostOperationClientProtocol
    private let store: SQLiteMailStore
    private let providerID: String
    private let providerName: String
    private let selectedAccountID: AccountID?
    private let requiresAccountScope: Bool
    private let expectedDirectSourceGeneration: Int64?

    init(
        client: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        providerID: String,
        providerName: String,
        selectedAccountID: AccountID? = nil,
        requiresAccountScope: Bool = false,
        isDeviceWide: Bool = false
    ) {
        self.isDeviceWide = isDeviceWide
        self.client = client
        self.store = store
        self.providerID = providerID
        self.providerName = providerName
        self.selectedAccountID = selectedAccountID
        self.requiresAccountScope = requiresAccountScope
        expectedDirectSourceGeneration = requiresAccountScope
            ? selectedAccountID.flatMap { try? store.explicitMailSource(accountID: $0)?.generation }
            : nil
    }

    /// The device-wide runtime: every request runs under the message's own Direct account, at
    /// that account's current generation, instead of under one selected account.
    private let isDeviceWide: Bool

    /// The account and source generation a request about `messageID` runs under.
    private func scope(for messageID: MessageID) throws -> (AccountID, Int64?) {
        if isDeviceWide {
            guard let owner = store.accountID(forMessageID: messageID) else {
                throw PlainpostError.notFound("Message not found.")
            }
            return (owner, try DeviceMailScope.requireCurrentOwner(owner, expected: nil, in: store))
        }
        return (try accountID(for: messageID), expectedDirectSourceGeneration)
    }

    private func requireCurrent(_ accountID: AccountID, _ generation: Int64?) throws {
        if isDeviceWide {
            try DeviceMailScope.requireCurrentOwner(accountID, expected: generation, in: store)
        } else {
            try requireCurrentDirectSource()
        }
    }

    private func requireCurrentDirectSource() throws {
        guard requiresAccountScope else { return }
        guard let selectedAccountID, let expectedDirectSourceGeneration,
              let source = try store.explicitMailSource(accountID: selectedAccountID),
              source.kind == .direct, source.generation == expectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("The selected Direct mail source changed.")
        }
    }

    private func accountID(for messageID: MessageID) throws -> AccountID {
        guard !requiresAccountScope || selectedAccountID != nil else {
            throw PlainpostError.permissionDenied("No account is selected for thread AI.")
        }
        try requireCurrentDirectSource()
        return try store.operationAccountID(
            forMessageID: messageID,
            explicitAccountID: selectedAccountID
        )
    }

    private func artifact(id: String, accountID: AccountID) throws -> DurableOperationArtifact {
        if selectedAccountID != nil || isDeviceWide {
            return try store.durableOperationArtifact(id: id, accountID: accountID)
        }
        return try store.durableOperationArtifact(id: id)
    }

    private func operationReference(
        for message: MessageSummary,
        accountID: AccountID
    ) throws -> PlainpostAIConversationReference {
        try store.aiConversationReference(
            messageID: message.id,
            threadID: message.threadID,
            accountID: accountID
        )
    }

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        let (accountID, generation) = try scope(for: messageID)
        guard let selectedMessage = store.messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let conversationKey = MailThreading.conversationKey(for: selectedMessage)
        let operationReference = try operationReference(for: selectedMessage, accountID: accountID)
        let threadMessages = store.messages(accountID: isDeviceWide ? accountID : selectedAccountID)
            .filter { MailThreading.conversationKey(for: $0) == conversationKey }
            .sorted {
                let lhsDate = $0.sentAt ?? .distantPast
                let rhsDate = $1.sentAt ?? .distantPast
                return lhsDate == rhsDate ? $0.id.rawValue < $1.id.rawValue : lhsDate < rhsDate
            }
        try requireCurrent(accountID, generation)
        let result = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .summarizeThread,
                recordID: operationReference.recordID,
                conversationReferenceKind: operationReference.kind,
                accountID: accountID,
                expectedDirectSourceGeneration: generation,
                providerID: providerID
            )
        )
        try requireCurrent(accountID, generation)
        let artifact = try artifact(id: result.artifactID, accountID: accountID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        return ThreadAIAssistantSummaryResult(
            summaryText: payload.text ?? "Summary completed.",
            providerName: providerName,
            modelID: payload.modelID ?? providerID,
            localOnly: payload.localOnly,
            contextMessageIDs: threadMessages.map(\.id.rawValue)
        )
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        let (accountID, generation) = try scope(for: messageID)
        guard let source = store.messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let operationReference = try operationReference(for: source, accountID: accountID)
        try requireCurrent(accountID, generation)
        let result = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .draftReply,
                recordID: operationReference.recordID,
                conversationReferenceKind: operationReference.kind,
                accountID: accountID,
                expectedDirectSourceGeneration: generation,
                providerID: providerID,
                question: instructions.isEmpty ? nil : instructions,
                draftTone: tone.rawValue
            )
        )
        try requireCurrent(accountID, generation)
        let artifact = try artifact(id: result.artifactID, accountID: accountID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        guard let draftID = payload.resultRecordID else {
            throw PlainpostError.notFound("Reply draft is unavailable.")
        }
        let draft = try store.draft(id: DraftID(draftID))
        guard selectedAccountID == nil && !isDeviceWide || draft.accountID == accountID else {
            throw PlainpostError.permissionDenied("The reply draft does not belong to the selected account.")
        }
        return draft
    }

    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        let (accountID, generation) = try scope(for: messageID)
        guard let selectedMessage = store.messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let operationReference = try operationReference(for: selectedMessage, accountID: accountID)
        try requireCurrent(accountID, generation)
        let result = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .answerThreadQuestion,
                recordID: operationReference.recordID,
                conversationReferenceKind: operationReference.kind,
                accountID: accountID,
                expectedDirectSourceGeneration: generation,
                providerID: providerID,
                question: question,
                conversation: priorTurns.map {
                    PlainpostAIConversationTurn(question: $0.question, answer: $0.answer)
                }
            )
        )
        try requireCurrent(accountID, generation)
        let artifact = try artifact(id: result.artifactID, accountID: accountID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        guard let answer = payload.text else {
            throw PlainpostError.notFound("Thread answer is unavailable.")
        }
        return ThreadAIAssistantAnswerResult(
            answer: answer,
            providerName: providerName,
            modelID: payload.modelID ?? providerID,
            localOnly: payload.localOnly
        )
    }
}

final class LocalOperationThreadTranslationService: ThreadTranslationHandling, @unchecked Sendable {
    let providerID: String
    let modelID: String

    private let client: any PlainpostOperationClientProtocol
    private let store: SQLiteMailStore
    private let provider: any AIProvider
    private let selectedAccountID: AccountID?
    private let requiresAccountScope: Bool
    private let expectedDirectSourceGeneration: Int64?

    init(
        client: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        provider: any AIProvider,
        selectedAccountID: AccountID? = nil,
        requiresAccountScope: Bool = false,
        isDeviceWide: Bool = false
    ) {
        self.isDeviceWide = isDeviceWide
        self.client = client
        self.store = store
        self.provider = provider
        self.selectedAccountID = selectedAccountID
        self.requiresAccountScope = requiresAccountScope
        expectedDirectSourceGeneration = requiresAccountScope
            ? selectedAccountID.flatMap { try? store.explicitMailSource(accountID: $0)?.generation }
            : nil
        providerID = provider.id
        modelID = provider.chatModelID
    }

    /// The device-wide runtime: every request runs under the message's own Direct account, at
    /// that account's current generation, instead of under one selected account.
    private let isDeviceWide: Bool

    /// The account and source generation a request about `messageID` runs under.
    private func scope(for messageID: MessageID) throws -> (AccountID, Int64?) {
        if isDeviceWide {
            guard let owner = store.accountID(forMessageID: messageID) else {
                throw PlainpostError.notFound("Message not found.")
            }
            return (owner, try DeviceMailScope.requireCurrentOwner(owner, expected: nil, in: store))
        }
        return (try accountID(for: messageID), expectedDirectSourceGeneration)
    }

    private func requireCurrent(_ accountID: AccountID, _ generation: Int64?) throws {
        if isDeviceWide {
            try DeviceMailScope.requireCurrentOwner(accountID, expected: generation, in: store)
        } else {
            try requireCurrentDirectSource()
        }
    }

    private func requireCurrentDirectSource() throws {
        guard requiresAccountScope else { return }
        guard let selectedAccountID, let expectedDirectSourceGeneration,
              let source = try store.explicitMailSource(accountID: selectedAccountID),
              source.kind == .direct, source.generation == expectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("The selected Direct mail source changed.")
        }
    }

    private func accountID(for messageID: MessageID) throws -> AccountID {
        guard !requiresAccountScope || selectedAccountID != nil else {
            throw PlainpostError.permissionDenied("No account is selected for translation.")
        }
        let accountID = try store.operationAccountID(
            forMessageID: messageID, explicitAccountID: selectedAccountID
        )
        try requireCurrentDirectSource()
        return accountID
    }

    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> MessageTranslationResult? {
        var scoped: (AccountID, Int64?)?
        if isDeviceWide {
            scoped = try scope(for: messageID)
        } else if requiresAccountScope {
            _ = try accountID(for: messageID)
        }
        let cached = try LocalMailTranslationService(provider: provider, store: store)
            .cachedTranslation(
                TranslateMessageInput(
                    messageID: messageID,
                    targetLanguageID: targetLanguageID,
                    targetLanguageName: targetLanguageID
                )
            )
        if let scoped {
            try requireCurrent(scoped.0, scoped.1)
        } else {
            try requireCurrentDirectSource()
        }
        return cached
    }

    func translate(
        messageID: MessageID,
        targetLanguageID: String,
        targetLanguageName: String
    ) async throws -> MessageTranslationResult {
        let (accountID, generation) = try scope(for: messageID)
        if let cached = try cachedTranslation(
            messageID: messageID,
            targetLanguageID: targetLanguageID
        ) {
            return cached
        }

        try requireCurrent(accountID, generation)
        let operation = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .translateMessage,
                recordID: messageID.rawValue,
                accountID: accountID,
                expectedDirectSourceGeneration: generation,
                providerID: providerID,
                modelID: modelID,
                targetLanguageIdentifier: targetLanguageID,
                targetLanguageName: targetLanguageName
            )
        )
        try requireCurrent(accountID, generation)
        let artifact = try selectedAccountID == nil && !isDeviceWide
            ? store.durableOperationArtifact(id: operation.artifactID)
            : store.durableOperationArtifact(id: operation.artifactID, accountID: accountID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        guard payload.resultRecordID == messageID.rawValue,
              payload.modelID == modelID,
              let translatedBodyKind = payload.translatedBodyKind,
              let translatedBody = payload.translatedBody,
              let sourceFingerprint = payload.sourceFingerprint,
              let cached = try cachedTranslation(
                  messageID: messageID,
                  targetLanguageID: targetLanguageID
              ),
              cached.renderedBody.kind.rawValue == translatedBodyKind,
              (cached.renderedBody.safeHTML ?? cached.renderedBody.safeText) == translatedBody,
              cached.sourceFingerprint == sourceFingerprint else {
            throw PlainpostError.validationFailed(
                "Translation operation did not produce a valid cached translation."
            )
        }
        return cached
    }
}

/// Ask Mail over a cached read-only mailbox (offline lease). The operation
/// queue writes job rows, which a read-only store refuses, so the answer is
/// built in place from the cached mail. Nothing is written.
final class CachedMailAskMailService: AskMailHandling, @unchecked Sendable {
    private let provider: any AIProvider
    private let store: SQLiteMailStore
    private let selectedAccountID: AccountID?
    private let requiresAccountScope: Bool
    typealias Answerer = @Sendable (AskMailboxQuestionInput, Actor) async throws -> MailboxQuestionAnswer
    private let answerer: Answerer

    /// - Parameter answerer: builds the answer; tests replace it to prove the ownership check.
    /// The device-wide runtime: every Direct account's cached mail, never a Sync Node one's.
    private let isDeviceWide: Bool

    init(provider: any AIProvider, store: SQLiteMailStore, selectedAccountID: AccountID?,
         requiresAccountScope: Bool, isDeviceWide: Bool = false, answerer: Answerer? = nil) {
        self.isDeviceWide = isDeviceWide
        self.provider = provider
        self.store = store
        self.selectedAccountID = selectedAccountID
        self.requiresAccountScope = requiresAccountScope
        self.answerer = answerer ?? { [provider, store] input, actor in
            try await AskMailAnswerService(provider: provider, store: store).answer(input, actor: actor)
        }
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        try await ask(question: question, scope: scope, activeContext: activeContext, priorTurns: priorTurns,
                      filterOverride: nil)
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn],
        filterOverride: AskMailFilterOverride?
    ) async throws -> MailboxQuestionAnswer {
        guard !requiresAccountScope || selectedAccountID != nil || isDeviceWide else {
            throw PlainpostError.permissionDenied("Select a mail account before asking about mail.")
        }
        guard provider.isPermittedMailProcessor else { throw AIProviderError.remoteEndpointDisallowed }
        let allowedMessageIDs: Set<MessageID>? = isDeviceWide
            ? try DeviceMailScope.current(in: store).accountIDs.reduce(into: Set<MessageID>()) {
                $0.formUnion(try store.accountMessageIDs(accountID: $1))
            }
            : try selectedAccountID.map { try store.accountMessageIDs(accountID: $0) }
        let scopedTurns = priorTurns.filter { turn in
            guard let allowedMessageIDs else { return true }
            return !turn.sources.isEmpty && turn.sources.allSatisfy { allowedMessageIDs.contains($0.messageID) }
        }
        let answer = try await answerer(
            AskMailboxQuestionInput(
                question: question,
                scope: scope,
                activeConversationKey: activeContext?.conversationKey,
                accountID: selectedAccountID,
                priorTurns: scopedTurns.suffix(6).map {
                    MailboxConversationTurn(question: $0.question, answer: $0.answer.text)
                },
                filterOverride: filterOverride
            ),
            Actor(id: "local-operation-agent", kind: .system,
                  displayName: "Local Operation Agent", permissions: .guiUser)
        )
        if let allowedMessageIDs {
            guard answer.sources.allSatisfy({ allowedMessageIDs.contains($0.messageID) }),
                  answer.askMailAnswer?.referencedMessageIDs.isSubset(of: allowedMessageIDs) ?? true else {
                throw PlainpostError.permissionDenied("Mailbox answer contains another account's evidence.")
            }
        }
        return answer
    }
}

final class LocalOperationAskMailService: AskMailHandling, @unchecked Sendable {
    private let client: any PlainpostOperationClientProtocol
    private let store: SQLiteMailStore
    private let providerID: String
    private let providerName: String
    private let selectedAccountID: AccountID?
    private let requiresAccountScope: Bool
    private let expectedDirectSourceGeneration: Int64?

    init(
        client: any PlainpostOperationClientProtocol,
        store: SQLiteMailStore,
        providerID: String,
        providerName: String,
        selectedAccountID: AccountID? = nil,
        requiresAccountScope: Bool = false,
        isDeviceWide: Bool = false
    ) {
        self.isDeviceWide = isDeviceWide
        self.client = client
        self.store = store
        self.providerID = providerID
        self.providerName = providerName
        self.selectedAccountID = selectedAccountID
        self.requiresAccountScope = requiresAccountScope
        expectedDirectSourceGeneration = requiresAccountScope
            ? selectedAccountID.flatMap { try? store.explicitMailSource(accountID: $0)?.generation }
            : nil
    }

    /// The device-wide runtime: Ask Mail searches every Direct account's mail, and its answer may
    /// cite only those accounts' messages.
    private let isDeviceWide: Bool

    /// The messages an answer may cite: one account's, every Direct account's, or (nil) any.
    private func allowedMessageIDs() throws -> Set<MessageID>? {
        if isDeviceWide {
            return try DeviceMailScope.current(in: store).accountIDs.reduce(into: Set<MessageID>()) {
                $0.formUnion(try store.accountMessageIDs(accountID: $1))
            }
        }
        return try selectedAccountID.map { try store.accountMessageIDs(accountID: $0) }
    }

    private func requireCurrentDirectSource() throws {
        guard requiresAccountScope, !isDeviceWide else { return }
        guard let selectedAccountID, let expectedDirectSourceGeneration,
              let source = try store.explicitMailSource(accountID: selectedAccountID),
              source.kind == .direct, source.generation == expectedDirectSourceGeneration else {
            throw PlainpostError.permissionDenied("The selected Direct mail source changed.")
        }
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn]
    ) async throws -> MailboxQuestionAnswer {
        try await ask(question: question, scope: scope, activeContext: activeContext, priorTurns: priorTurns,
                      filterOverride: nil)
    }

    func ask(
        question: String,
        scope: MailRetrievalScope,
        activeContext: AskMailActiveContext?,
        priorTurns: [AskMailTurn],
        filterOverride: AskMailFilterOverride?
    ) async throws -> MailboxQuestionAnswer {
        guard !requiresAccountScope || selectedAccountID != nil || isDeviceWide else {
            throw PlainpostError.permissionDenied("Select a mail account before asking about mail.")
        }
        try requireCurrentDirectSource()
        let allowedMessageIDs = try allowedMessageIDs()
        let scopedTurns = priorTurns.filter { turn in
            guard let allowedMessageIDs else { return true }
            return !turn.sources.isEmpty && turn.sources.allSatisfy { allowedMessageIDs.contains($0.messageID) }
        }
        try requireCurrentDirectSource()
        let result = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .answerMailboxQuestion,
                recordID: "mailbox",
                accountID: selectedAccountID,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration,
                providerID: providerID,
                question: question,
                conversation: scopedTurns.suffix(6).map {
                    PlainpostAIConversationTurn(question: $0.question, answer: $0.answer.text)
                },
                retrievalScope: scope,
                activeConversationKey: activeContext?.conversationKey,
                askMailFilterOverride: filterOverride
            )
        )
        try requireCurrentDirectSource()
        let artifact: DurableOperationArtifact
        if let selectedAccountID {
            artifact = try store.durableOperationArtifact(
                id: result.artifactID, accountID: selectedAccountID)
            guard artifact.kind == PlainpostAIOperationKind.answerMailboxQuestion.rawValue,
                  artifact.recordID == "mailbox" else {
                throw PlainpostError.validationFailed("The mailbox answer artifact is invalid.")
            }
        } else {
            artifact = try store.durableOperationArtifact(id: result.artifactID)
        }
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        guard let answer = payload.text else {
            throw PlainpostError.notFound("Mailbox answer is unavailable.")
        }
        if selectedAccountID != nil || isDeviceWide, let currentAllowed = try self.allowedMessageIDs() {
            guard payload.sources.allSatisfy({ currentAllowed.contains($0.messageID) }) else {
                throw PlainpostError.permissionDenied("Mailbox answer contains another account's evidence.")
            }
            guard payload.askMailAnswer?.referencedMessageIDs.isSubset(of: currentAllowed) ?? true else {
                throw PlainpostError.permissionDenied("Mailbox answer contains another account's evidence.")
            }
        }
        return MailboxQuestionAnswer(
            answer: answer,
            sources: payload.sources,
            insufficientEvidence: payload.insufficientEvidence ?? payload.sources.isEmpty,
            providerName: providerName,
            modelID: payload.modelID ?? providerID,
            localOnly: payload.localOnly,
            retrievalMode: MailRetrievalMode(rawValue: payload.retrievalMode ?? "lexical") ?? .lexical,
            askMailAnswer: payload.askMailAnswer
        )
    }
}
