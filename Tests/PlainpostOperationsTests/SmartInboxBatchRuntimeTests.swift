import Foundation
import SQLite3
import Testing
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport

@Test func approvedProfileUsesOneFourMessageProviderCall() async throws {
    let provider = ControlledBatchProvider()
    let context = try BatchRuntimeContext(messageCount: 4, provider: provider)
    try context.saveProfile(maxMessages: 4)

    let completed = try await context.run()

    #expect(completed.state == .completed)
    #expect(await provider.requestIDs() == [["msg_0", "msg_1", "msg_2", "msg_3"]])
}

@Test func missingProfileAlwaysUsesSingleMessageCalls() async throws {
    let provider = ControlledBatchProvider()
    let context = try BatchRuntimeContext(messageCount: 4, provider: provider)

    let completed = try await context.run()

    #expect(completed.state == .completed)
    #expect(await provider.requestIDs() == [["msg_0"], ["msg_1"], ["msg_2"], ["msg_3"]])
}

@Test func configuredOllamaModelIdentityIsDurableAcrossBatchExecution() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-ollama-model-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    for index in 0..<4 {
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("ollama_msg_\(index)"),
                threadID: nil,
                from: EmailAddress("sender\(index)@example.com"),
                subject: "Configured model \(index)",
                preview: "Use the selected local Ollama model",
                smartCategory: .unknown
            )
        )
    }
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "ollama"
    ).resolvingSmartInboxClassifierIdentity(
        environment: ["PLAINPOST_OLLAMA_CHAT_MODEL": "gemma3:12b"]
    )
    let identity = input.resolvedSmartInboxClassifierIdentity
    try store.saveSmartInboxBatchProfile(
        .init(
            providerID: identity.providerID,
            modelID: identity.modelID,
            classifierDiscriminator: identity.discriminator,
            maxMessageCount: 4,
            maxPromptCharacters: 6_000,
            memoryCeilingBytes: nil,
            benchmarkedAt: Date()
        )
    )
    guard case .job(let queued) = try store.enqueueSmartInboxJob(input: input) else {
        Issue.record("Expected configured Ollama work")
        return
    }
    let provider = ControlledBatchProvider(providerID: "ollama")
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        environment: ["PLAINPOST_OLLAMA_CHAT_MODEL": "ignored-after-enqueue:1b"],
        allowedJobKinds: [.aiOperation, .searchRebuild],
        aiProviderResolver: { _ in provider }
    )

    let completed = try #require(await runtime.processNextJob())

    let durableInput = try JSONDecoder().decode(
        PlainpostAIOperationInput.self,
        from: Data(queued.payloadJSON.utf8)
    )
    #expect(durableInput.modelID == "gemma3:12b")
    #expect(durableInput.resolvedSmartInboxClassifierIdentity == identity)
    #expect(await provider.requestIDs() == [[
        "ollama_msg_0", "ollama_msg_1", "ollama_msg_2", "ollama_msg_3",
    ]])
    #expect(try store.smartInboxClassificationCache().values.allSatisfy {
        $0.providerID == "ollama" && $0.modelID == "gemma3:12b"
    })
    let artifact = try store.durableOperationArtifact(id: try #require(completed.resultArtifactID))
    let payload = try JSONDecoder().decode(
        PlainpostLocalAIArtifactPayload.self,
        from: Data(artifact.payloadJSON.utf8)
    )
    #expect(payload.modelID == "gemma3:12b")
}

@Test func typedIdentityCanonicalizesMismatchedProviderAcrossExecutionAndProvenance() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-provider-identity-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    for index in 0..<2 {
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("provider_identity_msg_\(index)"),
                threadID: nil,
                from: EmailAddress("sender\(index)@example.com"),
                subject: "Provider identity \(index)",
                preview: "Use one authoritative classifier identity",
                smartCategory: .unknown
            )
        )
    }
    let identity = SmartInboxClassifierIdentity(
        providerID: "controlled-batch",
        modelID: "controlled-model",
        schemaVersion: SmartInboxClassifierContract.schemaVersion,
        promptVersion: SmartInboxClassifierContract.promptVersion
    )
    try store.saveSmartInboxBatchProfile(
        .init(
            providerID: identity.providerID,
            modelID: identity.modelID,
            classifierDiscriminator: identity.discriminator,
            maxMessageCount: 2,
            maxPromptCharacters: 6_000,
            memoryCeilingBytes: nil,
            benchmarkedAt: Date()
        )
    )
    let malformedInput = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "foundation",
        modelID: "apple-foundation-system",
        smartInboxClassifierIdentity: identity
    )
    guard case .job(let queued) = try store.enqueueSmartInboxJob(input: malformedInput) else {
        Issue.record("Expected mismatched provider work")
        return
    }
    let durableInput = try JSONDecoder().decode(
        PlainpostAIOperationInput.self,
        from: Data(queued.payloadJSON.utf8)
    )
    let provider = ControlledBatchProvider(providerID: identity.providerID)
    let selectionRecorder = LockedProviderSelectionRecorder()
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation, .searchRebuild],
        aiProviderResolver: { input in
            selectionRecorder.append(input.providerID)
            return provider
        }
    )

    let completed = try #require(await runtime.processNextJob())

    #expect(durableInput.providerID == identity.providerID)
    #expect(durableInput.modelID == identity.modelID)
    #expect(selectionRecorder.providerIDs == [identity.providerID])
    #expect(await provider.requestIDs() == [["provider_identity_msg_0", "provider_identity_msg_1"]])
    #expect(try store.smartInboxClassificationCache().values.allSatisfy {
        $0.providerID == identity.providerID && $0.modelID == identity.modelID
    })
    let artifact = try store.durableOperationArtifact(id: try #require(completed.resultArtifactID))
    let payload = try JSONDecoder().decode(
        PlainpostLocalAIArtifactPayload.self,
        from: Data(artifact.payloadJSON.utf8)
    )
    #expect(payload.modelID == identity.modelID)
}

@Test func smartInboxProviderResolutionReusesOnlyTheFullDurableClassifierIdentity() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-provider-cache-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let provider = ControlledBatchProvider(providerID: "foundation")
    let resolutions = LockedProviderSelectionRecorder()
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { input in
            resolutions.append(input.resolvedSmartInboxClassifierIdentity.discriminator)
            return provider
        }
    )
    let first = smartInboxProviderInput(modelID: "model-a")
    let changed = smartInboxProviderInput(modelID: "model-b")

    _ = try runtime.resolveAIProvider(
        first,
        smartInboxClassifierIdentity: first.resolvedSmartInboxClassifierIdentity
    )
    _ = try runtime.resolveAIProvider(
        first,
        smartInboxClassifierIdentity: first.resolvedSmartInboxClassifierIdentity
    )
    _ = try runtime.resolveAIProvider(
        changed,
        smartInboxClassifierIdentity: changed.resolvedSmartInboxClassifierIdentity
    )

    #expect(resolutions.providerIDs == [
        first.resolvedSmartInboxClassifierIdentity.discriminator,
        changed.resolvedSmartInboxClassifierIdentity.discriminator,
    ])
}

@Test func smartInboxProviderResolutionDoesNotReuseFailureOrNonLocalProvider() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-provider-cache-failure-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let input = smartInboxProviderInput(modelID: "model-a")
    let failures = LockedReadCounter()
    let failingRuntime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { _ in
            failures.increment()
            throw AIProviderError.unavailable
        }
    )

    for _ in 0..<2 {
        #expect(throws: AIProviderError.self) {
            try failingRuntime.resolveAIProvider(
                input,
                smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
            )
        }
    }
    #expect(failures.value == 2)

    let nonLocal = ControlledBatchProvider(providerID: "foundation", runsLocally: false)
    let nonLocalResolutions = LockedReadCounter()
    let nonLocalRuntime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { _ in
            nonLocalResolutions.increment()
            return nonLocal
        }
    )

    for _ in 0..<2 {
        let resolved = try nonLocalRuntime.resolveAIProvider(
            input,
            smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
        )
        #expect(!resolved.capabilities.runsLocally)
    }
    #expect(nonLocalResolutions.value == 2)
}

@Test func simultaneousSmartInboxProviderResolutionIsSingleFlight() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-provider-single-flight-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let input = smartInboxProviderInput(modelID: "model-a")
    let provider = ControlledBatchProvider(providerID: "foundation")
    let resolutions = LockedReadCounter()
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { _ in
            resolutions.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return provider
        }
    )
    let start = ProviderResolutionStartGate(participants: 2)

    let first = Task {
        await start.arriveAndWait()
        return try runtime.resolveAIProvider(
            input,
            smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
        )
    }
    let second = Task {
        await start.arriveAndWait()
        return try runtime.resolveAIProvider(
            input,
            smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
        )
    }

    let resolved = try await [first.value, second.value]
    #expect(resolved.allSatisfy { $0.id == provider.id })
    #expect(resolutions.value == 1)
}

@Test func smartInboxProviderResolutionRejectsReentrancyWithoutDeadlock() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-provider-reentrancy-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let input = smartInboxProviderInput(modelID: "model-a")
    let runtimeReference = LockedOperationRuntimeReference()
    let attempts = LockedReadCounter()
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { input in
            attempts.increment()
            return try runtimeReference.value.resolveAIProvider(
                input,
                smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
            )
        }
    )
    runtimeReference.set(runtime)

    #expect(throws: PlainpostError.self) {
        try runtime.resolveAIProvider(
            input,
            smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
        )
    }
    #expect(attempts.value == 1)
}

@Test func partialResponsePersistsValidResultsBeforeHalvingUnresolvedWork() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0"), validCandidate("msg_1")])),
        .response(.init(results: [validCandidate("msg_2"), validCandidate("msg_3")])),
    ])
    let persistence = LockedPersistenceRecorder()

    let report = try await makeRunnerInput(count: 4, provider: provider, persistence: persistence)

    #expect(report.terminalFailures.isEmpty)
    #expect(await provider.requestIDs() == [
        ["msg_0", "msg_1", "msg_2", "msg_3"], ["msg_2", "msg_3"],
    ])
    #expect(persistence.messageIDs == ["msg_0", "msg_1", "msg_2", "msg_3"])

    let invalidRecoveryProvider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0"), validCandidate("msg_1")])),
        .response(.init(results: [])),
        .response(.init(results: [])),
        .response(.init(results: [])),
    ])
    let invalidPersistence = LockedPersistenceRecorder()
    let invalidReport = try await makeRunnerInput(
        count: 4,
        provider: invalidRecoveryProvider,
        persistence: invalidPersistence
    )

    #expect(await invalidRecoveryProvider.requestIDs() == [
        ["msg_0", "msg_1", "msg_2", "msg_3"], ["msg_2", "msg_3"], ["msg_2"], ["msg_3"],
    ])
    #expect(invalidPersistence.messageIDs == ["msg_0", "msg_1"])
    #expect(invalidReport.terminalFailures.map(\.messageID) == ["msg_2", "msg_3"])
}

@Test func promptSplitFailureHalvesFromActualFourItemRequestUnderMaxSixteenProfile() async throws {
    let (items, messagesByID) = runnerFixtures(count: 8)
    let orderedMessages = items.compactMap { messagesByID[MessageID($0.messageID)] }
    let fourMessageRequest = AIClassificationBatchRequest(
        messages: orderedMessages.prefix(4).map(AIClassificationMessage.init)
    )
    let promptLimit = SmartInboxClassificationPrompt.render(fourMessageRequest).count
    let planned = try SmartInboxBatchBuilder.makeRequests(
        messages: orderedMessages,
        limits: .init(maxMessages: 16, maxPromptCharacters: promptLimit)
    )
    #expect(planned.map(\.messages.count) == [4, 4])
    let requests = RequestSizeRecorder()
    let persistence = LockedPersistenceRecorder()

    let report = try await SmartInboxBatchRunner().run(
        items: items,
        messagesByID: messagesByID,
        limits: .init(maxMessages: 16, maxPromptCharacters: promptLimit),
        classify: { request in
            await requests.append(request.messages.count)
            if request.messages.count == 4 {
                throw AIProviderError.unavailable
            }
            return AIClassificationBatchResponse(
                results: request.messages.map { validCandidate($0.id.rawValue) }
            )
        },
        persist: { persistence.append(item: $0, classification: $1) },
        shouldYield: { false }
    )

    #expect(report.terminalFailures.isEmpty)
    #expect(await requests.counts == [4, 2, 2, 4, 2, 2])
    #expect(persistence.messageIDs.count == 8)
}

@Test func lowConfidenceValidResultIsPersistedWithoutFallback() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0", confidence: 0.01)])),
    ])
    let persistence = LockedPersistenceRecorder()

    let report = try await makeRunnerInput(count: 1, provider: provider, persistence: persistence)

    #expect(report.terminalFailures.isEmpty)
    #expect(persistence.classifications.map(\.confidence) == [0.01])
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func singleMessageInvalidResultUsesDurableJobRetry() async throws {
    let provider = ControlledBatchProvider(responses: [.response(.init(results: []))])
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider)

    do {
        _ = try await context.processNextJob()
        Issue.record("Expected the terminal item failure to request durable retry")
    } catch {
        #expect(error is AIProviderError)
    }

    let job = try context.currentJob()
    #expect(job.state == .queued)
    #expect(try context.store.smartInboxWorkSummary(jobID: job.id).failed == 1)
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func partialFailureAppliesValidMessagesAndCompletesWithFailedCount() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
        .response(.init(results: [])),
    ])
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)

    let completed = try #require(await context.processNextJob())

    #expect(completed.state == .completed)
    let summary = try context.store.smartInboxWorkSummary(jobID: completed.id)
    #expect(summary.categorized == 1)
    #expect(summary.unchanged == 0)
    #expect(summary.failed == 1)
    let messages = try context.store.smartInboxListMessages()
    #expect(
        messages.first { $0.id == MessageID("msg_0") }?
            .smartCategory == .newsletter
    )
    #expect(
        messages.first { $0.id == MessageID("msg_1") }?
            .smartCategory == .unknown
    )
}

@Test func unchangedTerminalFailureDoesNotScheduleAnotherIncrementalRun() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
        .response(.init(results: [])),
    ])
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    _ = try #require(await context.processNextJob())
    let unchangedInput = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: provider.id,
        modelID: "controlled-model"
    )
    let reopenedStore = try SQLiteMailStore(path: context.databaseURL.path)
    try reopenedStore.migrate()

    guard case .upToDate = try reopenedStore.enqueueSmartInboxJob(input: unchangedInput) else {
        Issue.record("Expected unchanged terminal failure to remain suppressed")
        return
    }

    let changedClassifier = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: provider.id,
        modelID: "controlled-model-v2"
    )
    guard case .job = try reopenedStore.enqueueSmartInboxJob(input: changedClassifier) else {
        Issue.record("Expected changed classifier identity to make the message eligible")
        return
    }

    let explicitRerun = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: provider.id,
        modelID: "controlled-model",
        smartInboxRunMode: .rerunAll,
        smartInboxRequestID: "explicit-retry"
    )
    guard case .job = try reopenedStore.enqueueSmartInboxJob(input: explicitRerun) else {
        Issue.record("Expected an explicit rerun to bypass failure suppression")
        return
    }
}

@Test func artifactPersistsUpdatedUnchangedAndFailedCountsSeparately() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
        .response(.init(results: [validCandidate("msg_1")])),
        .response(.init(results: [])),
    ])
    let context = try BatchRuntimeContext(
        messageCount: 3,
        provider: provider,
        initialCategories: [.unknown, .newsletter, .unknown],
        initialConfidence: 0.9
    )

    let completed = try #require(await context.processNextJob())
    let artifactID = try #require(completed.resultArtifactID)
    let artifact = try context.store.durableOperationArtifact(id: artifactID)
    let payload = try JSONDecoder().decode(
        PlainpostLocalAIArtifactPayload.self,
        from: Data(artifact.payloadJSON.utf8)
    )

    #expect(payload.categorizedMessageCount == 1)
    #expect(payload.unchangedMessageCount == 1)
    #expect(payload.failedMessageCount == 1)
    #expect(completed.errorCode == "SMART_INBOX_PARTIAL_FAILURE")
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(artifact.payloadJSON.utf8)) as? [String: Any]
    )
    let diagnostics = try #require(
        object["smartInboxFailureDiagnostics"] as? [[String: Any]]
    )
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0]["code"] as? String == "validation.missing_result")
    #expect(diagnostics[0]["count"] as? Int == 1)
}

@Test func artifactPersistsProviderFailureClassWithoutRawProviderError() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
        .failure,
    ])
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)

    let completed = try #require(await context.processNextJob())
    let artifact = try context.store.durableOperationArtifact(
        id: try #require(completed.resultArtifactID)
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(artifact.payloadJSON.utf8)) as? [String: Any]
    )
    let diagnostics = try #require(
        object["smartInboxFailureDiagnostics"] as? [[String: Any]]
    )

    #expect(diagnostics.count == 1)
    #expect(diagnostics[0]["code"] as? String == "provider.unavailable")
    #expect(diagnostics[0]["count"] as? Int == 1)
}

@Test func artifactRecordsConservativeFoundationFallbacksAsSuccessfulWork() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
        .error(.unsupportedLanguageOrLocale),
        .error(.guardrailViolation),
    ])
    let context = try BatchRuntimeContext(messageCount: 3, provider: provider)

    let completed = try #require(await context.processNextJob())
    let artifact = try context.store.durableOperationArtifact(
        id: try #require(completed.resultArtifactID)
    )
    let payload = try JSONDecoder().decode(
        PlainpostLocalAIArtifactPayload.self,
        from: Data(artifact.payloadJSON.utf8)
    )

    #expect(completed.errorCode == nil)
    #expect(payload.failedMessageCount == 0)
    #expect(payload.smartInboxFailureDiagnostics == nil)
    let messages = try context.store.smartInboxListMessages().sorted { $0.id.rawValue < $1.id.rawValue }
    #expect(messages.map(\.smartCategory) == [.newsletter, .unknown, .unknown])
    #expect(messages.map(\.smartPriority) == [.normal, .high, .high])
    #expect(messages.map(\.smartRequiresAction) == [false, true, true])
    #expect(messages.map(\.smartConfidence) == [0.9, 0, 0])
}

@Test(arguments: [
    AIProviderError.guardrailViolation,
    AIProviderError.unsupportedLanguageOrLocale,
])
func deterministicFoundationFailureUsesConservativeFallbackWithoutDurableRetry(
    error: AIProviderError
) async throws {
    let provider = ControlledBatchProvider(responses: [.error(error)])
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider)

    let completed = try #require(await context.processNextJob())

    #expect(completed.state == .completed)
    #expect(completed.errorCode == nil)
    #expect(completed.resultArtifactID != nil)
    let message = try #require(context.store.smartInboxListMessages().first)
    #expect(message.smartCategory == .unknown)
    #expect(message.smartPriority == .high)
    #expect(message.smartRequiresAction == true)
    #expect(message.smartConfidence == 0)
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func accountScopedRunReconcilesOnlyThatAccountsMessageAndLabels() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-account-scope-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let accountA = Account(
        id: AccountID("account-a"),
        displayName: "Account A",
        email: EmailAddress("a@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
    let accountB = Account(
        id: AccountID("account-b"),
        displayName: "Account B",
        email: EmailAddress("b@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
    try store.cacheAccounts([accountA, accountB])
    for (id, title, accountID) in [
        ("account-a-label", "Account A Label", accountA.id),
        ("account-b-label", "Account B Label", accountB.id),
    ] {
        try store.saveMailLabel(
            try MailLabelDefinition.validated(
                id: id,
                title: title,
                description: "\(title) classification",
                isSmartInboxEnabled: true,
                scope: .account(accountID),
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }
    for (index, account) in [accountA, accountB].enumerated() {
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("account_\(index)_message"),
                threadID: nil,
                from: EmailAddress("sender\(index)@example.com"),
                subject: "Scoped \(index)",
                preview: "Only one account is eligible",
                smartCategory: .unknown,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                body: "Scoped plain body \(index)"
            ),
            metadata: .init(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: index + 1,
            notificationEligible: false
        )
    }
    let provider = ControlledBatchProvider(responses: [
        .response(
            .init(
                results: [
                    validCandidate(
                        "account_0_message",
                        labels: [
                            .init(id: "account-a-label", confidence: 0.92)
                        ]
                    ),
                ]
            )
        ),
    ])
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: provider.id,
        modelID: "controlled-model",
        smartInboxRunRequest: .init(
            mode: .rerunAll,
            scope: .account(accountA.id),
            requestedLabelID: nil
        ),
        smartInboxRequestID: UUID().uuidString
    )
    guard case .job(let job) = try store.enqueueSmartInboxJob(input: input) else {
        Issue.record("Expected an account-scoped rerun job.")
        return
    }
    for account in [accountA, accountB] {
        let syncInput = PlainpostInboxSyncInput(
            accountID: account.id,
            trigger: .manual
        )
        _ = try store.enqueueJob(
            .init(
                kind: .inboxSync,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(syncInput),
                    as: UTF8.self
                ),
                priority: 100,
                idempotencyKey: "account-scope-sync-\(account.id.rawValue)"
            )
        )
        let maybeSync = try store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        let sync = try #require(maybeSync)
        try store.completeJob(
            id: sync.id,
            leaseToken: try #require(sync.leaseToken),
            resultArtifactID: nil
        )
    }
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { [provider] _ in provider }
    )

    let completed = try #require(await runtime.processNextJob())

    #expect(completed.id == job.id)
    #expect(completed.state == .completed)
    #expect(await provider.requestIDs() == [["account_0_message"]])
    #expect(
        await provider.requests().first?.labels.map(\.id)
            == ["account-a-label"]
    )
    let messages = try store.smartInboxListMessages()
    #expect(
        messages.first { $0.id == MessageID("account_0_message") }?.smartCategory
            == .newsletter
    )
    #expect(
        messages.first { $0.id == MessageID("account_1_message") }?.smartCategory
            == .unknown
    )
    #expect(
        try store.labelAssignments(for: MessageID("account_0_message"))
            .filter { $0.source == .smartInbox }
            .map(\.labelID)
            == ["account-a-label"]
    )
    #expect(try store.labelAssignments(for: MessageID("account_1_message")).isEmpty)
}

@Test func nonLocalProviderFailsBeforeAnyClassificationRequest() async throws {
    let provider = ControlledBatchProvider(runsLocally: false)
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider)

    do {
        _ = try await context.processNextJob()
        Issue.record("Expected a non-local provider to be rejected.")
    } catch {
        #expect(error is AIProviderError)
    }

    #expect(await provider.requests().isEmpty)
    #expect(try context.store.smartInboxWorkSummary(jobID: context.currentJob().id).total == 0)
}

@Test func nonLocalClientFailsBeforeSmartInboxBodyInputQuery() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-nonlocal-read-gate-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let inputReads = LockedReadCounter()
    let store = try SQLiteMailStore(
        path: databaseURL.path,
        busyTimeout: 5,
        onTransientContention: nil,
        onSmartInboxClassificationInputRead: {
            inputReads.increment()
        }
    )
    try store.migrate()
    try store.cacheOwnedTestMessage(
        MessageSummary(
            id: MessageID("private_body"),
            threadID: nil,
            from: EmailAddress("private@example.com"),
            subject: "Private",
            preview: "Do not load the body",
            body: "BODY-MUST-NOT-BE-QUERIED",
            smartCategory: .unknown
        )
    )
    let provider = ControlledBatchProvider(runsLocally: false)
    let runtime = LocalOperationRuntime(
        store: store,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { [provider] _ in provider }
    )
    let client = LocalOperationClient(runtime: runtime)

    let execution = Task { () -> (any Error)? in
        do {
            _ = try await client.executeAI(
                PlainpostAIOperationInput(
                    operation: .recategorizeInbox,
                    recordID: "",
                    providerID: provider.id
                )
            )
            return nil
        } catch {
            return error
        }
    }
    try await Task.sleep(for: .milliseconds(100))
    execution.cancel()
    let error = await execution.value

    #expect(error is AIProviderError)
    #expect(inputReads.value == 0)
    #expect(try store.jobs(limit: 10).isEmpty)
    #expect(await provider.requests().isEmpty)
}

@Test func nonLocalQueuedClientFailsBeforeSmartInboxBodyInputQuery() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-nonlocal-queued-read-gate-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let inputReads = LockedReadCounter()
    let store = try SQLiteMailStore(
        path: databaseURL.path,
        busyTimeout: 5,
        onTransientContention: nil,
        onSmartInboxClassificationInputRead: {
            inputReads.increment()
        }
    )
    try store.migrate()
    try store.cacheOwnedTestMessage(
        MessageSummary(
            id: MessageID("private_queued_body"),
            threadID: nil,
            from: EmailAddress("private@example.com"),
            subject: "Private queued",
            preview: "Do not load the body",
            body: "QUEUED-BODY-MUST-NOT-BE-QUERIED",
            smartCategory: .unknown
        )
    )
    let provider = ControlledBatchProvider(runsLocally: false)
    let client = QueuedOperationClient(
        store: store,
        workerSignal: NoopOperationWorkerSignal(),
        aiProviderResolver: { [provider] _ in provider }
    )

    do {
        _ = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: provider.id
            )
        )
        Issue.record("Expected queued non-local classification to fail before enqueue.")
    } catch {
        #expect(error is AIProviderError)
    }

    #expect(inputReads.value == 0)
    #expect(try store.jobs(limit: 10).isEmpty)
    #expect(await provider.requests().isEmpty)
}

@Test func precomputedSmartInboxEnqueueDoesNotReadBodyAgain() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-precomputed-enqueue-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let inputReads = LockedReadCounter()
    let store = try SQLiteMailStore(
        path: databaseURL.path,
        busyTimeout: 5,
        onTransientContention: nil,
        onSmartInboxClassificationInputRead: {
            inputReads.increment()
        }
    )
    try store.migrate()
    try store.cacheOwnedTestMessage(
        MessageSummary(
            id: MessageID("precomputed_body"),
            threadID: nil,
            from: EmailAddress("private@example.com"),
            subject: "Precomputed",
            preview: "Load the body only at the validated boundary",
            body: "PRECOMPUTED-BODY",
            smartCategory: .unknown
        )
    )
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "deterministic"
    ).resolvingSmartInboxClassifierIdentity()
    let classificationInputs = try store.smartInboxClassificationInputs(
        scope: input.smartInboxRunRequest.scope
    )
    let catalogSnapshot = try store.smartInboxLabelCatalogSnapshot()

    _ = try store.enqueueSmartInboxJob(
        input: input,
        classificationInputs: classificationInputs,
        catalogSnapshot: catalogSnapshot
    )

    #expect(inputReads.value == 1)
}

@Test func v28RequeuesLegacyPreparedRerunAndRebuildsItAfterRelaunch() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-v28-relaunch-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let provider = ControlledBatchProvider()
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: provider.id,
        modelID: "controlled-model",
        smartInboxRunMode: .rerunAll,
        smartInboxRequestID: "legacy-rerun"
    )
    let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    let activeJobID: String
    let historicalJobID: String

    do {
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        for index in 0..<2 {
            try store.cacheOwnedTestMessage(
                MessageSummary(
                    id: MessageID("legacy_msg_\(index)"),
                    threadID: nil,
                    from: EmailAddress("legacy\(index)@example.com"),
                    subject: "Legacy \(index)",
                    preview: "Prepared before Task 6",
                    smartCategory: .unknown
                )
            )
        }
        let classificationInputs = try store.smartInboxClassificationInputs(
            scope: .allAccounts
        ).sorted { $0.message.id.rawValue < $1.message.id.rawValue }

        let historical = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: payload,
                priority: input.operation.priority,
                idempotencyKey: "legacy-historical-\(UUID().uuidString)"
            )
        )
        historicalJobID = historical.id
        let maybeHistoricalClaim = try store.claimNextJob(allowedKinds: [.aiOperation])
        let historicalClaim = try #require(maybeHistoricalClaim)
        let historicalLease = try #require(historicalClaim.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: historical.id,
            leaseToken: historicalLease,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: classificationInputs[0].message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInputs[0],
                        classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator
                    )
                ),
            ]
        )
        _ = try store.recordSmartInboxClassification(
            jobID: historical.id,
            leaseToken: historicalLease,
            ordinal: 0,
            category: .finance,
            providerID: provider.id,
            modelID: nil,
            actor: PlainpostFixtures.guiUser
        )
        try store.completeJob(
            id: historical.id,
            leaseToken: historicalLease,
            resultArtifactID: nil
        )

        let active = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: payload,
                priority: input.operation.priority,
                idempotencyKey: "legacy-active-\(UUID().uuidString)"
            )
        )
        activeJobID = active.id
        let maybeActiveClaim = try store.claimNextJob(allowedKinds: [.aiOperation])
        let activeClaim = try #require(maybeActiveClaim)
        let activeLease = try #require(activeClaim.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: active.id,
            leaseToken: activeLease,
            seeds: classificationInputs.enumerated().map { ordinal, classificationInput in
                .init(
                    ordinal: ordinal,
                    messageID: classificationInput.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator
                    )
                )
            }
        )
        _ = try store.recordSmartInboxClassification(
            jobID: active.id,
            leaseToken: activeLease,
            ordinal: 0,
            category: .finance,
            providerID: provider.id,
            modelID: nil,
            actor: PlainpostFixtures.guiUser
        )
        try store.pauseJob(
            id: active.id,
            leaseToken: activeLease,
            reason: "interactive-demand",
            progress: .init(
                current: 1,
                total: 2,
                phase: "paused",
                label: "Smart Inbox"
            )
        )
    }
    try executeBatchRuntimeSQL(
        "DELETE FROM grdb_migrations WHERE identifier = 'v28-smart-inbox-label-runtime';",
        at: databaseURL
    )

    let reopened = try SQLiteMailStore(path: databaseURL.path)
    try reopened.migrate()
    let reset = try reopened.job(id: activeJobID)
    #expect(reset.state == .queued)
    #expect(reset.leaseToken == nil)
    #expect(reset.pauseReason == nil)
    #expect(reset.progress == nil)
    #expect(try reopened.smartInboxWorkSummary(jobID: activeJobID).total == 0)
    #expect(try reopened.job(id: historicalJobID).state == .completed)
    #expect(try reopened.smartInboxWorkSummary(jobID: historicalJobID).total == 1)

    let runtime = LocalOperationRuntime(
        store: reopened,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation],
        aiProviderResolver: { [provider] _ in provider }
    )
    let relaunched = try #require(await runtime.processNextJob())

    #expect(relaunched.id == activeJobID)
    #expect(relaunched.state == .completed)
    let summary = try reopened.smartInboxWorkSummary(jobID: activeJobID)
    #expect(summary.total == 2)
    #expect(summary.processed == 2)
    #expect(summary.failed == 0)
    #expect(try reopened.smartInboxListMessages().allSatisfy { $0.smartCategory == .newsletter })
}

@Test func v28CancelsLegacyRunningPreparationWhenCancellationWasRequested() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-v28-cancelled-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "deterministic",
        smartInboxRunMode: .rerunAll,
        smartInboxRequestID: "legacy-cancelled-rerun"
    )
    let cancelledJobID: String
    let cancellationRequestedAt: Date

    do {
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("legacy_cancelled_message"),
                threadID: nil,
                from: EmailAddress("cancelled@example.com"),
                subject: "Cancel legacy work",
                preview: "Preserve cancellation across migration",
                smartCategory: .unknown
            )
        )
        let job = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: input.operation.priority,
                idempotencyKey: "legacy-cancelled-\(UUID().uuidString)"
            )
        )
        cancelledJobID = job.id
        let maybeRunning = try store.claimNextJob(allowedKinds: [.aiOperation])
        let running = try #require(maybeRunning)
        let leaseToken = try #require(running.leaseToken)
        let classificationInput = try #require(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: classificationInput.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator
                    )
                ),
            ]
        )
        try store.requestJobCancellation(id: job.id)
        let cancellationRequested = try store.job(id: job.id)
        #expect(cancellationRequested.state == .running)
        #expect(cancellationRequested.cancellationRequested)
        #expect(cancellationRequested.leaseToken != nil)
        #expect(try store.smartInboxWorkSummary(jobID: job.id).total == 1)
        cancellationRequestedAt = cancellationRequested.updatedAt
    }
    try executeBatchRuntimeSQL(
        "DELETE FROM grdb_migrations WHERE identifier = 'v28-smart-inbox-label-runtime';",
        at: databaseURL
    )

    let reopened = try SQLiteMailStore(path: databaseURL.path)
    try reopened.migrate()
    let cancelled = try reopened.job(id: cancelledJobID)

    #expect(cancelled.state == .cancelled)
    #expect(cancelled.cancellationRequested)
    #expect(cancelled.leaseToken == nil)
    #expect(cancelled.leaseExpiresAt == nil)
    #expect(cancelled.pauseReason == nil)
    #expect(cancelled.progress == nil)
    #expect(cancelled.resultArtifactID == nil)
    #expect(cancelled.errorCode == nil)
    #expect(cancelled.errorMessage == nil)
    #expect(cancelled.updatedAt > cancellationRequestedAt)
    #expect(try reopened.smartInboxWorkSummary(jobID: cancelledJobID).total == 0)
    #expect(try reopened.smartInboxLabelCatalogSnapshot(jobID: cancelledJobID) == nil)
    #expect(try reopened.activeSmartInboxRerunJob() == nil)

    let replacementInput = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "deterministic",
        smartInboxRunMode: .rerunAll,
        smartInboxRequestID: "replacement-rerun"
    )
    guard case .job(let replacement) = try reopened.enqueueSmartInboxJob(
        input: replacementInput
    ) else {
        Issue.record("Expected a replacement rerun after migrated cancellation.")
        return
    }
    #expect(replacement.id != cancelledJobID)
    let claimedReplacement = try #require(
        try reopened.claimNextJob(allowedKinds: [.aiOperation])
    )
    #expect(claimedReplacement.id == replacement.id)
    #expect(claimedReplacement.state == .running)
}

@Test func providerFailureKeepsThePreviousValidEnrichment() async throws {
    let provider = ControlledBatchProvider(responses: [.failure])
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider, enriched: true)

    do {
        _ = try await context.processNextJob(mode: .rerunAll)
        Issue.record("Expected the provider failure to request durable retry")
    } catch {
        #expect(error is AIProviderError)
    }

    let message = try #require(context.store.smartInboxListMessages().first)
    #expect(message.smartCategory == .finance)
    #expect(message.smartPriority == .high)
    #expect(message.smartRequiresAction == true)
    #expect(message.smartConfidence == 0.88)
}

@Test func staleTerminalFailureCompletesAsSkippedWithoutDurableRetry() async throws {
    let provider = ControlledBatchProvider(responses: [.failure])
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider)
    let store = context.store
    await provider.setBeforeResponse { _ in
        try! store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_0"),
                threadID: ThreadID("thread_0"),
                from: EmailAddress("sender0@example.com"),
                subject: "Subject 0",
                preview: "Changed while provider was running",
                smartCategory: .unknown
            )
        )
    }

    let completed = try #require(await context.processNextJob())

    #expect(completed.state == .completed)
    #expect(try context.store.smartInboxWorkSummary(jobID: completed.id) == .init(
        total: 1,
        processed: 1,
        categorized: 0,
        failed: 0
    ))
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func interactiveDemandYieldsBeforeTheNextRecoveryCall() async throws {
    let provider = ControlledBatchProvider(responses: [
        .response(.init(results: [validCandidate("msg_0")])),
    ])
    let persistence = LockedPersistenceRecorder()
    let yieldProbe = YieldProbe(yieldOnCheck: 3)
    let (items, messages) = runnerFixtures(count: 2)

    do {
        _ = try await SmartInboxBatchRunner().run(
            items: items,
            messagesByID: messages,
            limits: .init(maxMessages: 2, maxPromptCharacters: 6_000),
            classify: { try await provider.classifyBatch($0) },
            persist: { persistence.append(item: $0, classification: $1) },
            shouldYield: { await yieldProbe.shouldYield() }
        )
        Issue.record("Expected recovery to yield to interactive demand")
    } catch {
        #expect(error as? SmartInboxBatchRunnerError == .yieldRequested)
    }

    #expect(persistence.messageIDs == ["msg_0"])
    #expect(await provider.requestIDs() == [["msg_0", "msg_1"]])
}

@Test func schedulerControlFailureDoesNotBecomeTerminalProviderFailure() async throws {
    let (items, messages) = runnerFixtures(count: 1)

    await #expect(throws: SmartInboxSchedulerControlError.self) {
        try await SmartInboxBatchRunner().run(
            items: items,
            messagesByID: messages,
            limits: .init(maxMessages: 1, maxPromptCharacters: 6_000),
            classify: { _ in
                throw SmartInboxSchedulerControlError(
                    PlainpostError.validationFailed("injected scheduler control failure")
                )
            },
            persist: { _, _ in },
            shouldYield: { false }
        )
    }
}

// Seed the approved persisted policy directly so the original implementation
// compiles and fails at the actual enqueue/lease/provider-write boundaries.
// API roundtrip tests exercise the public setter after the owner contract exists.
private func seedSmartInboxEnabledPolicy(_ enabled: Bool, at databaseURL: URL) throws {
    try executeBatchRuntimeSQL("""
        CREATE TABLE IF NOT EXISTS smart_inbox_policy (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            enabled INTEGER NOT NULL CHECK(enabled IN (0, 1))
        );
        INSERT INTO smart_inbox_policy (singleton, enabled) VALUES (1, \(enabled ? 1 : 0))
        ON CONFLICT(singleton) DO UPDATE SET enabled = excluded.enabled;
        """, at: databaseURL)
    MailStoreChangeSignal.post(scope: .operations)
}

@Test func disabledSmartInboxPolicyBlocksSeparateServiceClaimAfterReopen() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    let queued = try context.enqueueJob(mode: .rerunAll)
    try seedSmartInboxEnabledPolicy(false, at: context.databaseURL)
    let serviceStore = try SQLiteMailStore(path: context.databaseURL.path)
    try serviceStore.migrate()
    #expect(try serviceStore.claimNextJob(allowedKinds: [.aiOperation]) == nil)
    #expect(try context.store.job(id: queued.id).state == .queued)
}

@Test func disabledSmartInboxPolicyRejectsOrganizingEnqueueButAllowsOtherAI() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    try seedSmartInboxEnabledPolicy(false, at: context.databaseURL)
    #expect(throws: (any Error).self) { try context.enqueueJob(mode: .rerunAll) }
    let input = PlainpostAIOperationInput(operation: .summarizeMessage, recordID: "msg_0", accountID: try #require(context.store.accounts.first?.id), providerID: "controlled-batch", enqueueOnly: true)
    let unrelated = try context.store.enqueueJob(.init(
        kind: .aiOperation,
        payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
        priority: input.operation.priority,
        idempotencyKey: "unrelated-ai-disabled-feature"
    ))
    #expect(try context.store.claimNextJob(allowedKinds: [.aiOperation])?.id == unrelated.id)
}

@Test func disabledSmartInboxPolicyFencesHeldProviderResultWithoutLateClassification() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()
    let work = Task { try await runtime.processNextJob() }
    await provider.waitUntilGatedRequestStarts()
    try seedSmartInboxEnabledPolicy(false, at: context.databaseURL)
    await provider.releaseGatedRequest()
    let paused = try #require(await work.value)
    #expect(paused.id == queued.id)
    #expect(paused.state == .paused)
    #expect(paused.pauseReason == "smart-inbox-disabled")
    #expect(paused.leaseToken == nil)
    #expect(try storedSmartInboxWork(databaseURL: context.databaseURL, jobID: paused.id) == [
        .init(state: .pending, category: nil), .init(state: .pending, category: nil)
    ])
    #expect(try context.store.smartInboxClassificationCache().isEmpty)
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func disabledSmartInboxPolicyAcknowledgesProviderCancellationAndJoinsHeldOwner() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    _ = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()
    let completion = SmartInboxOwnerCompletion()
    let work = Task {
        let result = try await runtime.processNextJob()
        await completion.markFinished()
        return result
    }
    await provider.waitUntilGatedRequestStarts()
    try seedSmartInboxEnabledPolicy(false, at: context.databaseURL)
    // A bounded positive wait for the actual cancellation handler; elapsed time
    // is only the failure deadline and is never evidence of cancellation/join.
    for _ in 0..<100 {
        if await provider.cancellationCount() > 0 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await provider.cancellationCount() == 1)
    #expect(await completion.hasFinished() == false)
    await provider.releaseGatedRequest()
    let result = try #require(await work.value)
    #expect(result.state == .paused)
    #expect(result.pauseReason == "smart-inbox-disabled")
    #expect(await completion.hasFinished())
    #expect(try context.store.smartInboxClassificationCache().isEmpty)
}

@Test func smartInboxPolicyDisabledOwnerRenewsLeaseUntilProviderJoin() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    let queued = try context.enqueueJob(mode: .rerunAll)
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let running = try #require(try context.store.claimNextJob(now: start, leaseDuration: 10, allowedKinds: [.aiOperation]))
    let token = try #require(running.leaseToken)
    try context.store.setSmartInboxEnabled(false)
    try context.store.renewJobLease(id: queued.id, leaseToken: token, now: start.addingTimeInterval(5), leaseDuration: 120)
    try context.store.setSmartInboxEnabled(true)
    #expect(try context.store.claimNextJob(now: start.addingTimeInterval(11), allowedKinds: [.aiOperation]) == nil)
    #expect(throws: SmartInboxPolicyError.disabled) {
        try context.store.prepareSmartInboxWork(jobID: queued.id, leaseToken: token, seeds: [])
    }

}

@Test func smartInboxPolicyOffRetainsOrdinaryInboxAndHistoryClaims() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    try context.store.setSmartInboxEnabled(false)
    let accountID = try #require(context.store.accounts.first?.id)
    for kind: PlainpostOperationKind in [.inboxSync, .historicalSync] {
        let input = PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: kind == .historicalSync ? .completeHistory : .incremental)
        let queued = try context.store.enqueueJob(.init(kind: kind,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: 100, idempotencyKey: "disabled-sync-\(kind.rawValue)"))
        let running = try #require(try context.store.claimNextJob(allowedKinds: [kind]))
        #expect(running.id == queued.id)
        try context.store.completeJob(id: running.id, leaseToken: try #require(running.leaseToken), resultArtifactID: nil)
        #expect(try context.store.job(id: queued.id).state == .completed)
    }
}

@Test func smartInboxPolicyAtomicWriteFencePreservesPriorClassificationAndPendingWork() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider(), enriched: true)
    let previous = try context.store.smartInboxClassificationCache()
    let queued = try context.enqueueJob(mode: .rerunAll)
    let running = try #require(try context.store.claimNextJob(allowedKinds: [.aiOperation]))
    let token = try #require(running.leaseToken)
    let input = try #require(context.store.smartInboxClassificationInputs(scope: .allAccounts).first)
    try context.store.prepareSmartInboxWork(jobID: queued.id, leaseToken: token, seeds: [
        .init(ordinal: 0, messageID: input.message.id.rawValue,
              sourceFingerprint: SmartInboxClassificationFingerprint.message(input,
                  classifierDiscriminator: SmartInboxClassifierContract.discriminator(providerID: "controlled-batch", modelID: "controlled-model")))
    ])
    let appConnection = try SQLiteMailStore(path: context.databaseURL.path)
    try appConnection.setSmartInboxEnabled(false)
    for _ in 0..<2 {
        #expect(throws: SmartInboxPolicyError.disabled) {
            try context.store.recordSmartInboxClassification(jobID: queued.id, leaseToken: token,
                ordinal: 0, category: .newsletter, providerID: "controlled-batch", modelID: "controlled-model",
                actor: PlainpostFixtures.guiUser)
        }
        #expect(throws: SmartInboxPolicyError.disabled) {
            try context.store.recordSmartInboxWorkItem(jobID: queued.id, leaseToken: token, ordinal: 0, state: .completed)
        }
        #expect(throws: SmartInboxPolicyError.disabled) {
            try context.store.applySmartInboxWork(jobID: queued.id, leaseToken: token, actor: PlainpostFixtures.guiUser)
        }
        #expect(throws: SmartInboxPolicyError.disabled) {
            try context.store.completeJob(id: queued.id, leaseToken: token, resultArtifactID: nil)
        }
        // The retained pause intent still fences this admitted lease after reenable.
        try appConnection.setSmartInboxEnabled(true)
    }
    #expect(try context.store.smartInboxClassificationCache() == previous)
    #expect(try storedSmartInboxWork(databaseURL: context.databaseURL, jobID: queued.id) == [.init(state: .pending, category: nil)])
}

@Test func smartInboxPolicyDefaultsAndPersistsAcrossSeparateOwnerRestart() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    #expect(try context.store.smartInboxEnabled())
    let queued = try context.enqueueJob(mode: .rerunAll)
    try context.store.setSmartInboxEnabled(false)
    try context.store.setSmartInboxEnabled(false)
    let reopened = try SQLiteMailStore(path: context.databaseURL.path)
    try reopened.migrate()
    #expect(try !reopened.smartInboxEnabled())
    #expect(try reopened.claimNextJob(allowedKinds: [.aiOperation]) == nil)
    try reopened.setSmartInboxEnabled(true)
    #expect(try context.store.smartInboxEnabled())
    #expect(try context.store.claimNextJob(allowedKinds: [.aiOperation])?.id == queued.id)
}

@Test func smartInboxPolicyRapidReenableRetainsCancelledProviderOwnerUntilJoin() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()
    let first = Task { try await runtime.processNextJob() }
    await provider.waitUntilGatedRequestStarts()
    try context.store.setSmartInboxEnabled(false)
    try context.store.setSmartInboxEnabled(true)
    for _ in 0..<100 {
        if await provider.cancellationCount() > 0 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await provider.cancellationCount() == 1)
    #expect(try context.store.job(id: queued.id).state == .running)
    #expect(try context.store.claimNextJob(allowedKinds: [.aiOperation]) == nil)
    await provider.releaseGatedRequest()
    let paused = try #require(await first.value)
    #expect(paused.state == .paused)
    #expect(paused.pauseReason == "smart-inbox-disabled")
    #expect(try context.store.smartInboxClassificationCache().isEmpty)
    let completed = try #require(await runtime.processNextJob())
    #expect(completed.id == queued.id)
    #expect(completed.state == .completed)
    #expect(completed.attempt == paused.attempt)
    #expect(await provider.requestIDs() == [["msg_0"], ["msg_0"], ["msg_1"]])
}

@Test func smartInboxPolicyManualPauseDuringDisabledOwnerWinsOnReenable() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()
    let first = Task { try await runtime.processNextJob() }
    await provider.waitUntilGatedRequestStarts()
    try context.store.setSmartInboxEnabled(false)
    try context.store.requestJobPause(id: queued.id)
    try context.store.setSmartInboxEnabled(true)
    await provider.releaseGatedRequest()
    let paused = try #require(await first.value)
    #expect(paused.state == .paused)
    #expect(paused.pauseReason == "user-requested")
    #expect(try await runtime.processNextJob() == nil)
    #expect(try context.store.smartInboxClassificationCache().isEmpty)
}

@Test func smartInboxPolicyExpiredFeatureIntentKeepsProvenanceAndManualOverride() throws {
    let context = try BatchRuntimeContext(messageCount: 2, provider: ControlledBatchProvider())
    let queued = try context.enqueueJob(mode: .rerunAll)
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    _ = try context.store.claimNextJob(now: start, leaseDuration: 10, allowedKinds: [.aiOperation])
    try context.store.setSmartInboxEnabled(false)
    let reopened = try SQLiteMailStore(path: context.databaseURL.path)
    try reopened.migrate()
    _ = try reopened.recoverBackgroundAgentJobs(allowedKinds: [.aiOperation], now: start.addingTimeInterval(11))
    let paused = try reopened.job(id: queued.id)
    #expect(paused.state == .paused)
    #expect(paused.pauseReason == "smart-inbox-disabled")
    #expect(paused.leaseToken == nil)
    try reopened.requestJobPause(id: queued.id)
    try reopened.setSmartInboxEnabled(true)
    #expect(try reopened.job(id: queued.id).pauseReason == "user-requested")
    #expect(try reopened.claimNextJob(now: start.addingTimeInterval(12), allowedKinds: [.aiOperation]) == nil)
}

private actor SmartInboxOwnerCompletion {
    private var finished = false
    func markFinished() { finished = true }
    func hasFinished() -> Bool { finished }
}

@Test func manualPauseCancelsTheInFlightRequestWithoutCheckpointingIt() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    _ = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()

    let work = Task {
        try await runtime.processNextJob()
    }
    await provider.waitUntilGatedRequestStarts()
    let running = try context.currentJob()
    let storedCatalogSnapshot = try context.store.smartInboxLabelCatalogSnapshot(jobID: running.id)
    let catalogSnapshot = try #require(storedCatalogSnapshot)

    try context.store.requestJobPause(id: running.id)
    await provider.releaseGatedRequest()
    let paused = try #require(try await work.value)

    #expect(paused.id == running.id)
    #expect(paused.state == .paused)
    #expect(paused.pauseRequested == false)
    #expect(paused.pauseReason == "user-requested")
    #expect(paused.leaseToken == nil)
    #expect(paused.leaseExpiresAt == nil)
    #expect(paused.attempt == running.attempt)
    #expect(paused.progress == .init(
        current: 0,
        total: 2,
        phase: "paused",
        label: "Smart Inbox"
    ))
    #expect(try context.store.smartInboxWorkSummary(jobID: paused.id) == .init(
        total: 2,
        processed: 0,
        categorized: 0,
        failed: 0
    ))
    #expect(
        try storedSmartInboxWork(databaseURL: context.databaseURL, jobID: paused.id)
            == [
                .init(state: .pending, category: nil),
                .init(state: .pending, category: nil),
            ]
    )
    #expect(
        try context.store.smartInboxLabelCatalogSnapshot(jobID: paused.id)
            == catalogSnapshot
    )
    #expect(await provider.requestIDs() == [["msg_0"]])
}

@Test func resumedManualPauseRetriesTheInterruptedPendingOrdinalThenContinues() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()

    let firstPass = Task {
        try await runtime.processNextJob()
    }
    await provider.waitUntilGatedRequestStarts()
    try context.store.requestJobPause(id: queued.id)
    await provider.releaseGatedRequest()
    let paused = try #require(try await firstPass.value)

    #expect(paused.id == queued.id)
    #expect(paused.state == .paused)
    #expect(
        try storedSmartInboxWork(databaseURL: context.databaseURL, jobID: paused.id)
            == [
                .init(state: .pending, category: nil),
                .init(state: .pending, category: nil),
            ]
    )

    try context.store.resumeUserPausedJob(id: paused.id, now: Date())
    let completed = try #require(await runtime.processNextJob())

    #expect(completed.id == queued.id)
    #expect(completed.state == .completed)
    #expect(completed.attempt == paused.attempt)
    #expect(await provider.requestIDs() == [["msg_0"], ["msg_0"], ["msg_1"]])
    #expect(
        try storedSmartInboxWork(databaseURL: context.databaseURL, jobID: completed.id)
            == [
                .init(state: .applied, category: .newsletter),
                .init(state: .applied, category: .newsletter),
            ]
    )
}

@Test func expiredPauseRequestRecoversAsManualPauseAfterRuntimeReopen() async throws {
    let provider = ControlledBatchProvider()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let leaseStart = Date(timeIntervalSince1970: 2_000_000_000)
    let running = try #require(
        try context.store.claimNextJob(
            now: leaseStart,
            leaseDuration: 10,
            allowedKinds: [.aiOperation, .searchRebuild]
        )
    )
    #expect(running.id == queued.id)
    try context.store.requestJobPause(id: running.id)
    #expect(try context.store.job(id: running.id).pauseRequested)

    let reopenedStore = try SQLiteMailStore(path: context.databaseURL.path)
    try reopenedStore.migrate()
    let reopenedRuntime = LocalOperationRuntime(
        store: reopenedStore,
        credentials: InMemoryCredentialVault(),
        allowedJobKinds: [.aiOperation, .searchRebuild],
        aiProviderResolver: { [provider] _ in provider }
    )
    let recovery = try reopenedStore.recoverBackgroundAgentJobs(
        allowedKinds: [.aiOperation, .searchRebuild],
        now: leaseStart.addingTimeInterval(11)
    )
    let paused = try reopenedStore.job(id: running.id)

    #expect(recovery.requeuedExpiredCount == 0)
    #expect(paused.id == queued.id)
    #expect(paused.state == .paused)
    #expect(paused.pauseRequested == false)
    #expect(paused.pauseReason == "user-requested")
    #expect(paused.leaseToken == nil)
    #expect(paused.leaseExpiresAt == nil)
    #expect(
        try await reopenedRuntime.processNextJob(now: leaseStart.addingTimeInterval(11))
            == nil
    )
    #expect(await provider.requests().isEmpty)
}

@Test func cancellationWinsWhenRequestedAfterPauseIntentBeforeCheckpoint() async throws {
    let provider = ControlledBatchProvider()
    await provider.gateNextRequest()
    let context = try BatchRuntimeContext(messageCount: 2, provider: provider)
    let queued = try context.enqueueJob(mode: .rerunAll)
    let runtime = context.makeRuntime()

    let work = Task {
        try await runtime.processNextJob()
    }
    await provider.waitUntilGatedRequestStarts()
    try context.store.requestJobPause(id: queued.id)
    try context.store.requestJobCancellation(id: queued.id)
    await provider.releaseGatedRequest()
    let cancelled = try #require(try await work.value)

    #expect(cancelled.id == queued.id)
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.cancellationRequested)
    #expect(cancelled.leaseToken == nil)
    #expect(cancelled.leaseExpiresAt == nil)
    #expect(await provider.requestIDs() == [["msg_0"]])
    #expect(throws: PlainpostError.self) {
        try context.store.resumeUserPausedJob(id: queued.id, now: Date())
    }
}

@Test func workerLoadsBoundedPlainTextButNeverHTML() async throws {
    let provider = ControlledBatchProvider()
    let context = try BatchRuntimeContext(messageCount: 1, provider: provider, bodyMarker: "BODY-MUST-NOT-LOAD")

    _ = try await context.run()

    let requests = await provider.requests()
    #expect(requests.count == 1)
    #expect(requests[0].messages[0].preview == "Preview 0")
    #expect(requests[0].messages[0].bodyExcerpt == "BODY-MUST-NOT-LOAD")
    #expect(!SmartInboxClassificationPrompt.render(requests[0]).contains("<p>"))
}

@Test func runnerUsesTheFrozenCatalogAndCompleteClassificationInput() async throws {
    let provider = ControlledBatchProvider()
    let persistence = LockedPersistenceRecorder()
    let (items, messages) = runnerFixtures(count: 1)
    let message = try #require(messages[MessageID("msg_0")])
    let input = SmartInboxClassificationInput(
        message: message,
        accountID: AccountID("account-a"),
        recipients: [EmailAddress("recipient@example.com")],
        bodyExcerpt: "bounded plain body"
    )
    let label = try MailLabelDefinition.validated(
        id: "frozen-label",
        title: "Frozen",
        description: "Frozen catalog entry",
        isSmartInboxEnabled: true,
        scope: .allAccounts
    )
    let catalog = MailLabelCatalogSnapshot(
        labels: [label],
        fingerprint: "frozen-fingerprint",
        createdAt: Date(timeIntervalSince1970: 100)
    )

    _ = try await SmartInboxBatchRunner().run(
        items: items,
        inputsByID: [message.id: input],
        catalog: catalog,
        limits: .init(maxMessages: 1, maxPromptCharacters: 6_000),
        classify: { try await provider.classifyBatch($0) },
        persist: { persistence.append(item: $0, classification: $1) },
        shouldYield: { false }
    )

    let request = try #require(await provider.requests().first)
    #expect(request.catalogFingerprint == "frozen-fingerprint")
    #expect(request.messages[0].recipients == ["recipient@example.com"])
    #expect(request.messages[0].bodyExcerpt == "bounded plain body")
    #expect(request.labels.map(\.id) == ["frozen-label"])
}

private func makeRunnerInput(
    count: Int,
    provider: ControlledBatchProvider,
    persistence: LockedPersistenceRecorder
) async throws -> SmartInboxBatchRunReport {
    let (items, messages) = runnerFixtures(count: count)
    return try await SmartInboxBatchRunner().run(
        items: items,
        messagesByID: messages,
        limits: .init(maxMessages: count, maxPromptCharacters: 6_000),
        classify: { try await provider.classifyBatch($0) },
        persist: { persistence.append(item: $0, classification: $1) },
        shouldYield: { false }
    )
}

private func runnerFixtures(count: Int) -> ([PlainpostSmartInboxWorkItem], [MessageID: MailboxListMessage]) {
    let messages = (0..<count).map { index in
        MailboxListMessage(
            id: MessageID("msg_\(index)"),
            threadID: nil,
            from: EmailAddress("sender\(index)@example.com"),
            subject: "Subject \(index)",
            preview: "Preview \(index)",
            smartCategory: .unknown
        )
    }
    let items = messages.enumerated().map { index, message in
        PlainpostSmartInboxWorkItem(
            jobID: "job",
            ordinal: index,
            messageID: message.id.rawValue,
            sourceFingerprint: "fingerprint-\(index)",
            state: .pending
        )
    }
    return (items, Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }))
}

private func smartInboxProviderInput(modelID: String) -> PlainpostAIOperationInput {
    let identity = SmartInboxClassifierIdentity(
        providerID: "foundation",
        modelID: modelID,
        schemaVersion: SmartInboxClassifierContract.schemaVersion,
        promptVersion: SmartInboxClassifierContract.promptVersion
    )
    return PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: identity.providerID,
        modelID: identity.modelID,
        smartInboxClassifierIdentity: identity
    )
}

private func validCandidate(
    _ id: String,
    confidence: Double = 0.9,
    labels: [AIClassificationLabelCandidate] = []
) -> AIClassificationCandidate {
    .init(
        id: id,
        category: SmartCategory.newsletter.rawValue,
        priority: SmartPriority.normal.rawValue,
        requiresAction: false,
        confidence: confidence,
        labels: labels
    )
}

private actor ControlledBatchProvider: AIProvider {
    nonisolated let id: String
    nonisolated let displayName = "Controlled Batch"
    nonisolated let capabilities: AICapabilities

    enum QueuedResponse: Sendable {
        case response(AIClassificationBatchResponse)
        case failure
        case error(AIProviderError)
    }

    private var queuedResponses: [QueuedResponse]
    private var recordedRequests: [AIClassificationBatchRequest] = []
    private var beforeResponse: (@Sendable (AIClassificationBatchRequest) -> Void)?
    private var shouldGateNextRequest = false
    private var gatedRequestStarted = false
    private var gatedRequestStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var gatedRequestReleaseContinuation: CheckedContinuation<Void, Never>?
    private var observedCancellationCount = 0

    init(
        providerID: String = "controlled-batch",
        responses: [QueuedResponse] = [],
        runsLocally: Bool = true
    ) {
        id = providerID
        capabilities = AICapabilities(
            supportsChat: true,
            supportsEmbeddings: false,
            supportsJSONMode: true,
            supportsStreaming: false,
            maxContextTokens: 4_096,
            runsLocally: runsLocally
        )
        queuedResponses = responses
    }

    func requests() -> [AIClassificationBatchRequest] { recordedRequests }
    func requestIDs() -> [[String]] { recordedRequests.map { $0.messages.map(\.id.rawValue) } }
    func gateNextRequest() {
        shouldGateNextRequest = true
        gatedRequestStarted = false
    }
    func waitUntilGatedRequestStarts() async {
        guard !gatedRequestStarted else { return }
        await withCheckedContinuation { continuation in
            gatedRequestStartWaiters.append(continuation)
        }
    }
    func releaseGatedRequest() {
        gatedRequestReleaseContinuation?.resume()
        gatedRequestReleaseContinuation = nil
    }
    func cancellationCount() -> Int { observedCancellationCount }
    private func recordCancellation() { observedCancellationCount += 1 }
    func setBeforeResponse(_ action: @escaping @Sendable (AIClassificationBatchRequest) -> Void) {
        beforeResponse = action
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        .init(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }

    func classifyBatch(_ request: AIClassificationBatchRequest) async throws -> AIClassificationBatchResponse {
        recordedRequests.append(request)
        beforeResponse?(request)
        if shouldGateNextRequest {
            shouldGateNextRequest = false
            gatedRequestStarted = true
            let waiters = gatedRequestStartWaiters
            gatedRequestStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    gatedRequestReleaseContinuation = continuation
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        guard !queuedResponses.isEmpty else {
            return .init(results: request.messages.map { validCandidate($0.id.rawValue) })
        }
        switch queuedResponses.removeFirst() {
        case .response(let response): return response
        case .failure: throw AIProviderError.unavailable
        case .error(let error): throw error
        }
    }
}

private final class LockedPersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(PlainpostSmartInboxWorkItem, SmartInboxClassification)] = []

    var messageIDs: [String] { lock.withLock { values.map { $0.0.messageID } } }
    var classifications: [SmartInboxClassification] { lock.withLock { values.map(\.1) } }

    func append(item: PlainpostSmartInboxWorkItem, classification: SmartInboxClassification) {
        lock.withLock { values.append((item, classification)) }
    }
}

private final class LockedProviderSelectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var providerIDs: [String] { lock.withLock { values } }

    func append(_ providerID: String) {
        lock.withLock { values.append(providerID) }
    }
}

private final class LockedReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor ProviderResolutionStartGate {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participants {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class LockedOperationRuntimeReference: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: LocalOperationRuntime?

    var value: LocalOperationRuntime {
        lock.withLock { runtime! }
    }

    func set(_ runtime: LocalOperationRuntime) {
        lock.withLock { self.runtime = runtime }
    }
}

private actor YieldProbe {
    private let yieldOnCheck: Int
    private var checkCount = 0

    init(yieldOnCheck: Int) { self.yieldOnCheck = yieldOnCheck }

    func shouldYield() -> Bool {
        checkCount += 1
        return checkCount >= yieldOnCheck
    }
}

private actor RequestSizeRecorder {
    private(set) var counts: [Int] = []

    func append(_ count: Int) {
        counts.append(count)
    }
}

private final class BatchRuntimeContext {
    let store: SQLiteMailStore
    let databaseURL: URL
    private let provider: ControlledBatchProvider
    private let modelID = "controlled-model"
    private var enqueuedJobID: String?

    init(
        messageCount: Int,
        provider: ControlledBatchProvider,
        enriched: Bool = false,
        bodyMarker: String = "",
        initialCategories: [SmartCategory] = [],
        initialConfidence: Double? = nil
    ) throws {
        self.provider = provider
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-batch-runtime-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        for index in 0..<messageCount {
            try store.cacheOwnedTestMessage(
                MessageSummary(
                    id: MessageID("msg_\(index)"),
                    threadID: ThreadID("thread_\(index)"),
                    from: EmailAddress("sender\(index)@example.com"),
                    subject: "Subject \(index)",
                    preview: "Preview \(index)",
                    body: bodyMarker,
                    bodyHTML: bodyMarker.isEmpty ? nil : "<p>\(bodyMarker)</p>",
                    smartCategory: initialCategories.indices.contains(index)
                        ? initialCategories[index]
                        : .unknown
                )
            )
        }
        if let initialConfidence {
            try executeBatchRuntimeSQL(
                "UPDATE messages SET smart_confidence = \(initialConfidence);",
                at: databaseURL
            )
        }
        if enriched {
            try seedEnrichment()
        }
    }

    deinit { try? FileManager.default.removeItem(at: databaseURL) }

    func saveProfile(maxMessages: Int) throws {
        try store.saveSmartInboxBatchProfile(
            .init(
                providerID: provider.id,
                modelID: modelID,
                classifierDiscriminator: SmartInboxClassifierContract.discriminator(
                    providerID: provider.id,
                    modelID: modelID
                ),
                maxMessageCount: maxMessages,
                maxPromptCharacters: 6_000,
                memoryCeilingBytes: nil,
                benchmarkedAt: Date()
            )
        )
    }

    func processNextJob(mode: PlainpostSmartInboxRunMode = .incremental) async throws -> PlainpostDurableJob? {
        _ = try enqueueJob(mode: mode)
        return try await makeRuntime().processNextJob()
    }

    func enqueueJob(mode: PlainpostSmartInboxRunMode = .incremental) throws -> PlainpostDurableJob {
        if let enqueuedJobID {
            return try store.job(id: enqueuedJobID)
        }
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id,
            modelID: modelID,
            smartInboxRunMode: mode,
            smartInboxRequestID: mode == .rerunAll ? UUID().uuidString : nil
        )
        let data = try JSONEncoder().encode(input)
        let job = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: input.operation.priority,
                idempotencyKey: "batch-runtime-\(UUID().uuidString)"
            )
        )
        enqueuedJobID = job.id
        return job
    }

    func makeRuntime() -> LocalOperationRuntime {
        LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { [provider] _ in provider }
        )
    }

    func run() async throws -> PlainpostDurableJob {
        try #require(await processNextJob())
    }

    func currentJob() throws -> PlainpostDurableJob {
        try store.job(id: try #require(enqueuedJobID))
    }

    private func seedEnrichment() throws {
        let classificationInput = try #require(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        let message = classificationInput.message
        let discriminator = SmartInboxClassifierContract.discriminator(
            providerID: provider.id,
            modelID: modelID
        )
        let seedJob = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "seed-enrichment-\(UUID().uuidString)"
            )
        )
        let maybeClaimed = try store.claimNextJob(allowedKinds: [.aiOperation])
        let claimed = try #require(maybeClaimed)
        let leaseToken = try #require(claimed.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: discriminator
                    )
                ),
            ]
        )
        _ = try store.recordSmartInboxClassification(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: .init(
                messageID: message.id,
                category: .finance,
                priority: .high,
                requiresAction: true,
                confidence: 0.88
            ),
            providerID: provider.id,
            modelID: modelID,
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.applySmartInboxWork(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try store.completeJob(id: seedJob.id, leaseToken: leaseToken, resultArtifactID: nil)
    }
}

private struct StoredSmartInboxWork: Equatable {
    let state: PlainpostSmartInboxWorkState
    let category: SmartCategory?
}

private func storedSmartInboxWork(
    databaseURL: URL,
    jobID: String
) throws -> [StoredSmartInboxWork] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw PlainpostError.validationFailed("Unable to open Smart Inbox work database.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT state, category FROM smart_inbox_work_items WHERE job_id = ? ORDER BY ordinal",
        -1,
        &statement,
        nil
    ) == SQLITE_OK,
          let statement else {
        throw PlainpostError.validationFailed("Unable to prepare Smart Inbox work query.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, jobID, -1, transient)
    var work: [StoredSmartInboxWork] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let rawState = sqlite3_column_text(statement, 0),
              let state = PlainpostSmartInboxWorkState(rawValue: String(cString: rawState)) else {
            throw PlainpostError.validationFailed("Smart Inbox work state is invalid.")
        }
        let category = sqlite3_column_text(statement, 1).flatMap {
            SmartCategory(rawValue: String(cString: $0))
        }
        work.append(.init(state: state, category: category))
    }
    return work
}

private func executeBatchRuntimeSQL(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(
            domain: "SmartInboxBatchRuntimeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to open test database."]
        )
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error."
        sqlite3_free(errorMessage)
        throw NSError(
            domain: "SmartInboxBatchRuntimeTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
