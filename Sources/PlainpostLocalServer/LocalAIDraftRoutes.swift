import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostLocalAPI
import PlainpostOperations

public struct LocalAPIAISummarizeParameters: Codable, Sendable {
    public let messageID: String

    public init(messageID: String) {
        self.messageID = messageID
    }
}

public struct LocalAPIReplyBeginParameters: Codable, Sendable {
    public let messageID: String

    public init(messageID: String) {
        self.messageID = messageID
    }
}

public struct LocalAPIDraftReadParameters: Codable, Sendable {
    public let draftID: String

    public init(draftID: String) {
        self.draftID = draftID
    }
}

public struct LocalAPIDraftUpdateParameters: Codable, Sendable {
    public let draftID: String
    public let body: String
    public let expectedHash: String

    public init(draftID: String, body: String, expectedHash: String) {
        self.draftID = draftID
        self.body = body
        self.expectedHash = expectedHash
    }
}

public struct LocalAPIAIDraftReplyParameters: Codable, Sendable {
    public let draftID: String
    public let messageID: String
    public let instruction: String
    public let expectedHash: String

    public init(draftID: String, messageID: String, instruction: String, expectedHash: String) {
        self.draftID = draftID
        self.messageID = messageID
        self.instruction = instruction
        self.expectedHash = expectedHash
    }
}

public struct LocalAPISummaryResult: Codable, Equatable, Sendable {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

public struct LocalAPIDraftResult: Codable, Equatable, Sendable {
    public let id: String
    public let subject: String
    public let to: [String]
    public let body: String
    public let contentHash: String
    public let aiGenerated: Bool

    public init(draft: Draft) {
        id = draft.id.rawValue
        subject = draft.subject
        to = draft.to.map(\.rawValue)
        body = draft.bodyPlain
        contentHash = draft.contentHash
        aiGenerated = draft.aiGenerated
    }
}

public final class AISummarizeRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.aiSummarize

    private let store: SQLiteMailStore
    private let aiClient: any PlainpostOperationClientProtocol
    private let selectedProviderID: @Sendable () -> String

    public init(
        store: SQLiteMailStore,
        aiClient: any PlainpostOperationClientProtocol,
        selectedProviderID: @escaping @Sendable () -> String
    ) {
        self.store = store
        self.aiClient = aiClient
        self.selectedProviderID = selectedProviderID
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIAISummarizeParameters> = try decodeRequest(requestData)
        let source = try sourceMessage(id: MessageID(request.parameters.messageID), store: store)
        let membership = try store.membership(for: source.id)
        let operation: PlainpostAIOperationKind = source.threadID == nil ? .summarizeMessage : .summarizeThread
        let recordID = source.threadID?.rawValue ?? source.id.rawValue
        let result = try await aiClient.executeAI(PlainpostAIOperationInput(
            operation: operation,
            recordID: recordID,
            accountID: membership.accountID,
            providerID: selectedProviderID()
        ))
        let payload = try aiPayload(result: result, store: store)
        guard let summary = payload.text else {
            throw LocalAPIRouteError(code: .unavailable, safeMessage: "The AI summary is unavailable.")
        }
        return try encodeSuccess(requestID: requestID, result: LocalAPISummaryResult(summary: summary))
    }
}

public final class ReplyBeginRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.replyBegin

    private let store: SQLiteMailStore

    public init(store: SQLiteMailStore) {
        self.store = store
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIReplyBeginParameters> = try decodeRequest(requestData)
        do {
            let messageID = MessageID(request.parameters.messageID)
            let source = try sourceMessage(id: messageID, store: store)
            let membership = try store.membership(for: messageID)
            guard let account = store.accounts.first(where: { $0.id == membership.accountID }) else {
                throw PlainpostError.notFound("Message account not found.")
            }
            let draft = try ReplyDraftFactory().makeDraft(
                source: source,
                account: account,
                actor: browserActor,
                id: DraftID("drf_browser_\(UUID().uuidString.lowercased())")
            )
            let persisted = try store.createDraft(draft, actor: browserActor)
            return try encodeSuccess(requestID: requestID, result: LocalAPIDraftResult(draft: persisted))
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
    }
}

public final class DraftReadRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.draftRead

    private let store: SQLiteMailStore

    public init(store: SQLiteMailStore) {
        self.store = store
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIDraftReadParameters> = try decodeRequest(requestData)
        do {
            let draft = try browserDraft(id: DraftID(request.parameters.draftID), store: store)
            return try encodeSuccess(requestID: requestID, result: LocalAPIDraftResult(draft: draft))
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
    }
}

public final class DraftUpdateRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.draftUpdate

    private let store: SQLiteMailStore

    public init(store: SQLiteMailStore) {
        self.store = store
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIDraftUpdateParameters> = try decodeRequest(requestData)
        let draftID = DraftID(request.parameters.draftID)
        _ = try browserDraft(id: draftID, store: store)
        do {
            let updated = try store.updateDraft(
                id: draftID,
                expectedHash: request.parameters.expectedHash,
                patch: DraftPatch(bodyPlain: request.parameters.body, bodyMarkdown: request.parameters.body),
                actor: browserActor,
                requiredIDPrefix: "drf_browser_",
                requiredCreatorID: browserActor.id
            )
            return try encodeSuccess(requestID: requestID, result: LocalAPIDraftResult(draft: updated))
        } catch DraftOptimisticUpdateError.conflict {
            throw draftConflictError()
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
    }
}

public final class AIDraftReplyRoute: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.aiDraftReply

    private let store: SQLiteMailStore
    private let aiClient: any PlainpostOperationClientProtocol
    private let selectedProviderID: @Sendable () -> String

    public init(
        store: SQLiteMailStore,
        aiClient: any PlainpostOperationClientProtocol,
        selectedProviderID: @escaping @Sendable () -> String
    ) {
        self.store = store
        self.aiClient = aiClient
        self.selectedProviderID = selectedProviderID
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIAIDraftReplyParameters> = try decodeRequest(requestData)
        let draftID = DraftID(request.parameters.draftID)
        let current = try browserDraft(id: draftID, store: store)
        try requireHash(request.parameters.expectedHash, matches: current)
        let source = try sourceMessage(id: MessageID(request.parameters.messageID), store: store)
        try requireSource(source, matches: current, store: store)
        let reference = try store.aiConversationReference(
            messageID: source.id,
            threadID: source.threadID,
            accountID: current.accountID
        )
        let result = try await aiClient.executeAI(PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: reference.recordID,
            conversationReferenceKind: reference.kind,
            accountID: current.accountID,
            providerID: selectedProviderID(),
            question: request.parameters.instruction
        ))
        let payload = try aiPayload(result: result, store: store)
        guard let generatedDraftID = payload.resultRecordID else {
            throw LocalAPIRouteError(code: .unavailable, safeMessage: "The AI draft is unavailable.")
        }
        let generated = try routeDraft(id: DraftID(generatedDraftID), store: store)

        do {
            let updated = try store.updateDraft(
                id: draftID,
                expectedHash: request.parameters.expectedHash,
                patch: DraftPatch(
                    bodyPlain: generated.bodyPlain,
                    bodyMarkdown: generated.bodyMarkdown ?? generated.bodyPlain,
                    aiGenerated: true
                ),
                actor: browserActor,
                requiredIDPrefix: "drf_browser_",
                requiredCreatorID: browserActor.id
            )
            return try encodeSuccess(requestID: requestID, result: LocalAPIDraftResult(draft: updated))
        } catch DraftOptimisticUpdateError.conflict {
            throw draftConflictError()
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
    }
}

let browserActor = Actor(
    id: "browser-extension-user",
    kind: .user,
    displayName: "Plainpost Browser Extension",
    permissions: .guiUser
)

private func sourceMessage(id: MessageID, store: SQLiteMailStore) throws -> MessageSummary {
    guard let source = try store.messageSummary(id: id) else {
        throw LocalAPIRouteError(code: .notFound, safeMessage: "Message not found.")
    }
    return source
}

private func routeDraft(id: DraftID, store: SQLiteMailStore) throws -> Draft {
    do {
        return try store.draft(id: id)
    } catch let error as PlainpostError {
        throw routeError(for: error)
    }
}

func browserDraft(id: DraftID, store: SQLiteMailStore) throws -> Draft {
    let draft = try routeDraft(id: id, store: store)
    guard id.rawValue.hasPrefix("drf_browser_"), draft.createdBy == browserActor.id else {
        throw LocalAPIRouteError(
            code: .permissionDenied,
            safeMessage: "This client cannot access that draft."
        )
    }
    return draft
}

private func requireSource(
    _ source: MessageSummary,
    matches draft: Draft,
    store: SQLiteMailStore
) throws {
    let membership: MailboxMessageMembership
    do {
        membership = try store.membership(for: source.id)
    } catch let error as PlainpostError {
        throw routeError(for: error)
    }
    let sourceMatches: Bool
    if let threadID = draft.sourceThreadID {
        sourceMatches = source.threadID == threadID
    } else {
        sourceMatches = source.threadID == nil
            && draft.inReplyTo != nil
            && draft.inReplyTo == source.rfcMessageID
    }
    guard membership.accountID == draft.accountID, sourceMatches else {
        throw LocalAPIRouteError(
            code: .invalidRequest,
            safeMessage: "The message does not match this draft."
        )
    }
}

func requireHash(_ expectedHash: String, matches draft: Draft) throws {
    guard draft.contentHash == expectedHash else {
        throw draftConflictError()
    }
}

private func draftConflictError() -> LocalAPIRouteError {
    LocalAPIRouteError(code: .conflict, safeMessage: "The draft changed. Reload it before editing.")
}

private func aiPayload(
    result: PlainpostAIOperationResult,
    store: SQLiteMailStore
) throws -> PlainpostLocalAIArtifactPayload {
    do {
        let artifact = try store.durableOperationArtifact(id: result.artifactID)
        return try JSONDecoder().decode(PlainpostLocalAIArtifactPayload.self, from: Data(artifact.payloadJSON.utf8))
    } catch {
        throw LocalAPIRouteError(code: .unavailable, safeMessage: "The AI result is unavailable.")
    }
}
