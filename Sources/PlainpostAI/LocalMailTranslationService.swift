import Foundation
import PlainpostCore

public struct TranslateMessageInput: Equatable, Sendable {
    public let messageID: MessageID
    public let targetLanguageID: String
    public let targetLanguageName: String

    public init(
        messageID: MessageID,
        targetLanguageID: String,
        targetLanguageName: String
    ) {
        self.messageID = messageID
        self.targetLanguageID = targetLanguageID
        self.targetLanguageName = targetLanguageName
    }
}

public struct MessageTranslationResult: Equatable, Sendable {
    public let messageID: MessageID
    public let renderedBody: RenderedEmailBody
    public let sourceFingerprint: String
    public let providerID: String
    public let modelID: String
    public let targetLanguageID: String
    public let wasCached: Bool

    public init(
        messageID: MessageID,
        renderedBody: RenderedEmailBody,
        sourceFingerprint: String,
        providerID: String,
        modelID: String,
        targetLanguageID: String,
        wasCached: Bool
    ) {
        self.messageID = messageID
        self.renderedBody = renderedBody
        self.sourceFingerprint = sourceFingerprint
        self.providerID = providerID
        self.modelID = modelID
        self.targetLanguageID = targetLanguageID
        self.wasCached = wasCached
    }
}

public final class LocalMailTranslationService<Store: LocalAIStore> {
    private let provider: any AIProvider
    private let store: Store

    public init(provider: any AIProvider, store: Store) {
        self.provider = provider
        self.store = store
    }

    public func cachedTranslation(
        _ input: TranslateMessageInput
    ) throws -> MessageTranslationResult? {
        guard let message = activeMessage(id: input.messageID),
              let cached = try store.cachedTranslation(
                  messageID: input.messageID,
                  targetLanguageID: input.targetLanguageID
              )
        else {
            return nil
        }

        let sourceFingerprint = MailTranslationFingerprint.message(message)
        guard cached.sourceFingerprint == sourceFingerprint,
              cached.targetLanguageID == input.targetLanguageID,
              cached.providerID == provider.id,
              cached.modelID == provider.chatModelID,
              cached.contractVersion == MailTranslationContract.version
        else {
            return nil
        }

        let renderedBody = MailTranslationDocument.renderTranslatedBody(
            cached.translatedBody,
            kind: cached.bodyKind
        )
        guard activeSourceFingerprint(for: message.id) == sourceFingerprint else {
            return nil
        }
        return MessageTranslationResult(
            messageID: message.id,
            renderedBody: renderedBody,
            sourceFingerprint: sourceFingerprint,
            providerID: cached.providerID,
            modelID: cached.modelID,
            targetLanguageID: cached.targetLanguageID,
            wasCached: true
        )
    }

    public func translateMessage(
        _ input: TranslateMessageInput,
        actor: Actor,
        expectedDirectSourceGeneration: Int64? = nil
    ) async throws -> MessageTranslationResult {
        try AIUsagePolicy.validateSummary(actor: actor)
        if let cached = try cachedTranslation(input) {
            return cached
        }
        guard let message = activeMessage(id: input.messageID) else {
            throw AIProviderError.notFound("Message not found.")
        }

        let sourceFingerprint = MailTranslationFingerprint.message(message)
        let sourceBody = if let html = message.bodyHTML {
            EmailBodyRenderer.render(.html(html))
        } else {
            RenderedEmailBody(
                kind: .plainText,
                safeText: message.body,
                blockedRemoteImageURLs: []
            )
        }
        let prepared = try MailTranslationDocument.prepare(sourceBody)
        var translatedSegments: [AITranslatedSegment] = []
        for batch in prepared.batches(maxUTF8Bytes: translationBatchUTF8Limit) {
            try Task.checkCancellation()
            let response = try await provider.translate(
                AITranslationRequest(
                    targetLanguageID: input.targetLanguageID,
                    targetLanguageName: input.targetLanguageName,
                    segments: batch
                )
            )
            guard response.modelID == provider.chatModelID else {
                throw PlainpostError.validationFailed(
                    "Translation response model does not match the configured provider model."
                )
            }
            translatedSegments.append(contentsOf: response.segments)
        }
        let renderedBody = try prepared.reconstruct(translatedSegments)
        try Task.checkCancellation()
        guard activeSourceFingerprint(for: message.id) == sourceFingerprint else {
            throw sourceChangedError
        }

        let now = Date()
        let translation = CachedMessageTranslation(
                messageID: message.id,
                targetLanguageID: input.targetLanguageID,
                sourceFingerprint: sourceFingerprint,
                providerID: provider.id,
                modelID: provider.chatModelID,
                contractVersion: MailTranslationContract.version,
                bodyKind: renderedBody.kind,
                translatedBody: renderedBody.safeHTML ?? renderedBody.safeText,
                createdAt: now,
                updatedAt: now
            )
        let saveResult: MailTranslationCacheSaveResult
        if let expectedDirectSourceGeneration {
            saveResult = try store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: sourceFingerprint,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration
            )
        } else {
            saveResult = try store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: sourceFingerprint
            )
        }
        guard saveResult == .saved else {
            throw sourceChangedError
        }
        guard activeSourceFingerprint(for: message.id) == sourceFingerprint else {
            throw sourceChangedError
        }

        return MessageTranslationResult(
            messageID: message.id,
            renderedBody: renderedBody,
            sourceFingerprint: sourceFingerprint,
            providerID: provider.id,
            modelID: provider.chatModelID,
            targetLanguageID: input.targetLanguageID,
            wasCached: false
        )
    }

    private var translationBatchUTF8Limit: Int {
        max(1_024, provider.capabilities.maxContextTokens / 2)
    }

    private func activeMessage(id: MessageID) -> MessageSummary? {
        store.messages.first { $0.id == id && !$0.isDeleted }
    }

    private func activeSourceFingerprint(for id: MessageID) -> String? {
        activeMessage(id: id).map(MailTranslationFingerprint.message)
    }

    private var sourceChangedError: PlainpostError {
        .validationFailed("Message changed during translation.")
    }
}
