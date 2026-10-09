import Foundation
import PlainpostAI
import PlainpostCore

public protocol ThreadTranslationHandling: Sendable {
    var providerID: String { get }
    var modelID: String { get }

    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> MessageTranslationResult?

    func translate(
        messageID: MessageID,
        targetLanguageID: String,
        targetLanguageName: String
    ) async throws -> MessageTranslationResult
}

public struct ThreadTranslationConfiguration: Equatable, Sendable {
    public let targetLanguageID: String
    public let targetLanguageName: String

    public init(targetLanguageID: String, targetLanguageName: String) {
        self.targetLanguageID = targetLanguageID
        self.targetLanguageName = targetLanguageName
    }
}

public enum ThreadTranslationDisplayMode: Equatable, Sendable {
    case original
    case translated
}

@MainActor
public final class ThreadTranslationViewModel: ObservableObject {
    @Published public private(set) var displayMode: ThreadTranslationDisplayMode
    @Published public private(set) var translatedBodies: [String: RenderedEmailBody]
    @Published public private(set) var completedMessageCount: Int
    @Published public private(set) var totalMessageCount: Int
    @Published public private(set) var isTranslating: Bool
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var actionAvailability: AIActionAvailability

    private var handler: any ThreadTranslationHandling
    private var availability: () -> AIActionAvailability
    private var requestGeneration = 0
    private var activeRequest: RequestIdentity?
    private var translationTask: Task<Void, Never>?
    private var translatedSourceFingerprints: [String: String] = [:]

    public init(
        handler: any ThreadTranslationHandling,
        availability: @escaping () -> AIActionAvailability = { .available }
    ) {
        self.handler = handler
        self.availability = availability
        actionAvailability = availability()
        displayMode = .original
        translatedBodies = [:]
        completedMessageCount = 0
        totalMessageCount = 0
        isTranslating = false
        statusMessage = nil
    }

    public var actionTitle: String {
        if displayMode == .translated {
            return "Show Original"
        }
        return hasCompleteTranslation ? "Show Translation" : "Translate"
    }

    public var progressText: String? {
        guard isTranslating else { return nil }
        return "\(completedMessageCount) of \(totalMessageCount)"
    }

    public func displayedBody(for message: ThreadMessageModel) -> RenderedEmailBody {
        if displayMode == .translated,
           translatedSourceFingerprints[message.id] == message.translationSourceFingerprint,
           let translated = translatedBodies[message.id] {
            return translated
        }
        return RenderedEmailBody(
            kind: message.bodyKind,
            safeText: message.safeBodyText,
            safeHTML: message.safeHTML,
            blockedRemoteImageURLs: message.blockedRemoteImageURLs
        )
    }

    public func prepare(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration
    ) async {
        let request = beginRequest(messages: messages, configuration: configuration)
        refreshAvailability()
        guard !messages.isEmpty else { return }

        do {
            let cached = try loadCachedBodies(messages: messages, configuration: configuration)
            guard isCurrent(request) else { return }
            completedMessageCount = cached.count
            if cached.count == messages.count {
                translatedBodies = cached
                translatedSourceFingerprints = sourceFingerprints(for: messages)
            }
        } catch {
            guard isCurrent(request) else { return }
            completedMessageCount = 0
            translatedBodies = [:]
        }
    }

    public func translate(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration
    ) async {
        if isTranslating,
           let activeRequest,
           activeRequest.matches(
               messages: messages,
               configuration: configuration,
               handler: handler
           ),
           let translationTask {
            await translationTask.value
            return
        }

        let request = beginRequest(messages: messages, configuration: configuration)
        guard !messages.isEmpty else { return }

        let cached: [String: RenderedEmailBody]
        do {
            cached = try loadCachedBodies(messages: messages, configuration: configuration)
        } catch {
            guard isCurrent(request) else { return }
            statusMessage = "Translation unavailable. Try again."
            return
        }
        guard isCurrent(request) else { return }
        completedMessageCount = cached.count
        if cached.count == messages.count {
            translatedBodies = cached
            translatedSourceFingerprints = sourceFingerprints(for: messages)
            displayMode = .translated
            return
        }

        refreshAvailability()
        guard actionAvailability.isAvailable else {
            statusMessage = actionAvailability.reason ?? "Translation is unavailable. Check AI Providers."
            return
        }

        isTranslating = true
        let currentHandler = handler
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTranslation(
                messages: messages,
                configuration: configuration,
                request: request,
                initialBodies: cached,
                handler: currentHandler
            )
        }
        translationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func showOriginal() {
        guard displayMode == .translated else { return }
        displayMode = .original
    }

    public func showTranslation() {
        guard hasCompleteTranslation else { return }
        displayMode = .translated
    }

    public func configure(
        handler: any ThreadTranslationHandling,
        availability: (() -> AIActionAvailability)? = nil
    ) {
        invalidateCurrentRequest()
        self.handler = handler
        if let availability {
            self.availability = availability
        }
        refreshAvailability()
    }

    public func refreshAvailability() {
        let previousReason = actionAvailability.reason
        actionAvailability = availability()
        if actionAvailability.isAvailable && statusMessage == previousReason {
            statusMessage = nil
        }
    }

    public func configurationDidChange() {
        invalidateCurrentRequest()
    }

    private var hasCompleteTranslation: Bool {
        totalMessageCount > 0
            && translatedBodies.count == totalMessageCount
            && translatedSourceFingerprints.count == totalMessageCount
    }

    private func beginRequest(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration
    ) -> RequestIdentity {
        translationTask?.cancel()
        translationTask = nil
        requestGeneration &+= 1
        let request = RequestIdentity(
            generation: requestGeneration,
            orderedMessageIDs: messages.map(\.id),
            orderedSourceFingerprints: messages.map(\.translationSourceFingerprint),
            targetLanguageID: configuration.targetLanguageID,
            providerID: handler.providerID,
            modelID: handler.modelID
        )
        activeRequest = request
        displayMode = .original
        translatedBodies = [:]
        translatedSourceFingerprints = [:]
        completedMessageCount = 0
        totalMessageCount = messages.count
        isTranslating = false
        statusMessage = nil
        return request
    }

    private func invalidateCurrentRequest() {
        translationTask?.cancel()
        translationTask = nil
        requestGeneration &+= 1
        activeRequest = nil
        displayMode = .original
        translatedBodies = [:]
        translatedSourceFingerprints = [:]
        completedMessageCount = 0
        totalMessageCount = 0
        isTranslating = false
        statusMessage = nil
    }

    private func loadCachedBodies(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration
    ) throws -> [String: RenderedEmailBody] {
        var bodies: [String: RenderedEmailBody] = [:]
        for message in messages {
            if let result = try handler.cachedTranslation(
                messageID: MessageID(message.id),
                targetLanguageID: configuration.targetLanguageID
            ) {
                try validate(
                    result,
                    messageID: message.id,
                    sourceFingerprint: message.translationSourceFingerprint,
                    configuration: configuration,
                    handler: handler
                )
                bodies[message.id] = result.renderedBody
            }
        }
        return bodies
    }

    private func performTranslation(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration,
        request: RequestIdentity,
        initialBodies: [String: RenderedEmailBody],
        handler: any ThreadTranslationHandling
    ) async {
        var bodies = initialBodies
        do {
            for message in messages where bodies[message.id] == nil {
                try Task.checkCancellation()
                let result = try await handler.translate(
                    messageID: MessageID(message.id),
                    targetLanguageID: configuration.targetLanguageID,
                    targetLanguageName: configuration.targetLanguageName
                )
                try Task.checkCancellation()
                try validate(
                    result,
                    messageID: message.id,
                    sourceFingerprint: message.translationSourceFingerprint,
                    configuration: configuration,
                    handler: handler
                )
                guard isCurrent(request) else { return }
                bodies[message.id] = result.renderedBody
                completedMessageCount = bodies.count
            }
            guard isCurrent(request), bodies.count == messages.count else { return }
            translatedBodies = bodies
            translatedSourceFingerprints = sourceFingerprints(for: messages)
            displayMode = .translated
            isTranslating = false
            statusMessage = nil
            translationTask = nil
        } catch is CancellationError {
            guard isCurrent(request) else { return }
            translatedBodies = [:]
            translatedSourceFingerprints = [:]
            displayMode = .original
            isTranslating = false
            statusMessage = nil
            translationTask = nil
        } catch {
            guard isCurrent(request) else { return }
            translatedBodies = [:]
            translatedSourceFingerprints = [:]
            displayMode = .original
            isTranslating = false
            statusMessage = "Translation unavailable. Try again."
            translationTask = nil
        }
    }

    private func validate(
        _ result: MessageTranslationResult,
        messageID: String,
        sourceFingerprint: String,
        configuration: ThreadTranslationConfiguration,
        handler: any ThreadTranslationHandling
    ) throws {
        guard result.messageID == MessageID(messageID),
              result.sourceFingerprint == sourceFingerprint,
              result.targetLanguageID == configuration.targetLanguageID,
              result.providerID == handler.providerID,
              result.modelID == handler.modelID else {
            throw ThreadTranslationViewModelError.invalidResult
        }
    }

    private func isCurrent(_ request: RequestIdentity) -> Bool {
        request.generation == requestGeneration && activeRequest == request
    }

    private func sourceFingerprints(
        for messages: [ThreadMessageModel]
    ) -> [String: String] {
        messages.reduce(into: [:]) {
            $0[$1.id] = $1.translationSourceFingerprint
        }
    }
}

private struct RequestIdentity: Equatable {
    let generation: Int
    let orderedMessageIDs: [String]
    let orderedSourceFingerprints: [String]
    let targetLanguageID: String
    let providerID: String
    let modelID: String

    func matches(
        messages: [ThreadMessageModel],
        configuration: ThreadTranslationConfiguration,
        handler: any ThreadTranslationHandling
    ) -> Bool {
        orderedMessageIDs == messages.map(\.id)
            && orderedSourceFingerprints == messages.map(\.translationSourceFingerprint)
            && targetLanguageID == configuration.targetLanguageID
            && providerID == handler.providerID
            && modelID == handler.modelID
    }
}

private enum ThreadTranslationViewModelError: Error {
    case invalidResult
}
