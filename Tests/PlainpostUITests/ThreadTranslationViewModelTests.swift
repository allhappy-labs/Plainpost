import Foundation
import PlainpostRuntimeTestSupport
import PlainpostServiceIPC
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostOperations
@testable import PlainpostUI

@MainActor final class ThreadTranslationViewModelTests: XCTestCase {
    func testUnavailableProviderPreventsNewTranslationAndShowsReason() async {
        let handler = RecordingThreadTranslationHandler()
        let reason = "Turn on Apple Intelligence in Settings to use Apple Foundation Models."
        let viewModel = ThreadTranslationViewModel(
            handler: handler,
            availability: { AIActionAvailability(isAvailable: false, reason: reason, canCheckAgain: true) }
        )
        let messages = Self.messages(count: 1, prefix: "unavailable")

        await viewModel.prepare(messages: messages, configuration: Self.french)
        await viewModel.translate(messages: messages, configuration: Self.french)

        XCTAssertFalse(viewModel.actionAvailability.isAvailable)
        XCTAssertEqual(viewModel.actionAvailability.reason, reason)
        XCTAssertEqual(viewModel.statusMessage, reason)
        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertTrue(handler.translateCallIDs.isEmpty)
    }

    func testAvailabilityRefreshAllowsTranslationAfterModelBecomesReady() async {
        let handler = RecordingThreadTranslationHandler()
        var isAvailable = false
        let viewModel = ThreadTranslationViewModel(
            handler: handler,
            availability: {
                isAvailable ? .available : AIActionAvailability(
                    isAvailable: false,
                    reason: "Apple Intelligence is preparing its model. Check again after the download completes.",
                    canCheckAgain: true
                )
            }
        )
        let messages = Self.messages(count: 1, prefix: "ready")

        await viewModel.translate(messages: messages, configuration: Self.french)
        isAvailable = true
        viewModel.refreshAvailability()
        await viewModel.translate(messages: messages, configuration: Self.french)

        XCTAssertTrue(viewModel.actionAvailability.isAvailable)
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(handler.translateCallIDs, ["ready-1"])
    }

    func testCachedTranslationRemainsViewableWhenProviderIsUnavailable() async {
        let message = Self.messages(count: 1, prefix: "cached-unavailable")[0]
        let handler = RecordingThreadTranslationHandler(
            cachedResults: [Self.cacheKey(messageID: message.id, languageID: "fr"): Self.result(for: message.id)]
        )
        let viewModel = ThreadTranslationViewModel(
            handler: handler,
            availability: { AIActionAvailability(isAvailable: false, reason: "Model unavailable") }
        )

        await viewModel.prepare(messages: [message], configuration: Self.french)
        await viewModel.translate(messages: [message], configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(viewModel.displayedBody(for: message).safeText, "Translated cached-unavailable-1")
        XCTAssertTrue(handler.translateCallIDs.isEmpty)
    }

    func testTranslationUsesDistinctInjectedServiceOperation() async throws {
        let client = RuntimeServiceClientFake()
        let operations = PlainpostServiceOperationAdapter(serviceClient: client)

        let result = try await operations.executeAI(
            PlainpostAIOperationInput(
                operation: .translateMessage, recordID: "message-1", providerID: "deterministic",
                targetLanguageIdentifier: "de", targetLanguageName: "German"))

        XCTAssertEqual(result.operation, .translateMessage)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.foregroundOperationKinds, [.translateMessage])
    }

    func testSuccessfulTranslationBecomesVisibleAtomicallyAndTogglesWithoutNewWork() async {
        let handler = RecordingThreadTranslationHandler()
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 2, prefix: "atomic")

        await viewModel.prepare(messages: messages, configuration: Self.french)
        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertEqual(viewModel.displayMode, .original)

        await viewModel.translate(messages: messages, configuration: Self.french)

        XCTAssertEqual(viewModel.actionTitle, "Show Original")
        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Translated atomic-1")
        XCTAssertEqual(viewModel.displayedBody(for: messages[1]).safeText, "Translated atomic-2")

        viewModel.showOriginal()
        XCTAssertEqual(viewModel.actionTitle, "Show Translation")
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Original atomic-1")
        XCTAssertEqual(handler.translateCallIDs, ["atomic-1", "atomic-2"])

        viewModel.showTranslation()
        XCTAssertEqual(viewModel.actionTitle, "Show Original")
        XCTAssertEqual(handler.translateCallIDs, ["atomic-1", "atomic-2"])
    }

    func testRepeatedTranslateForSameRequestCoalescesIntoOneOperationPerMessage() async {
        let handler = RecordingThreadTranslationHandler(suspendedMessageIDs: [
            "double-click-1", "double-click-2",
        ])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 2, prefix: "double-click")
        let first = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }
        await handler.waitForCallCount(1)

        let second = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(handler.translateCallIDs, ["double-click-1"])

        handler.resume(messageID: "double-click-1")
        await handler.waitForCallCount(2)
        XCTAssertEqual(handler.translateCallIDs, ["double-click-1", "double-click-2"])
        handler.resume(messageID: "double-click-2")
        await first.value
        await second.value

        XCTAssertEqual(handler.translateCallIDs, ["double-click-1", "double-click-2"])
        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(viewModel.actionTitle, "Show Original")
        XCTAssertEqual(
            viewModel.displayedBody(for: messages[0]).safeText,
            "Translated double-click-1"
        )
        XCTAssertEqual(
            viewModel.displayedBody(for: messages[1]).safeText,
            "Translated double-click-2"
        )
    }

    /// The iPhone conversation prepares translation on open, so a translation of the last
    /// conversation doesn't carry over as "Show Original" over this one's untranslated bodies.
    func testPreparingTheNextConversationShowsItsOriginals() async {
        let viewModel = ThreadTranslationViewModel(handler: RecordingThreadTranslationHandler())
        let first = Self.messages(count: 1, prefix: "first")
        let second = Self.messages(count: 1, prefix: "second")
        await viewModel.translate(messages: first, configuration: Self.french)
        XCTAssertEqual(viewModel.displayMode, .translated)

        await viewModel.prepare(messages: second, configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertEqual(viewModel.displayedBody(for: second[0]).safeText, "Original second-1")
    }

    func testPrepareAfterRestartOffersCacheWithoutDisplayingIt() async {
        let messages = Self.messages(count: 2, prefix: "restart")
        let handler = RecordingThreadTranslationHandler(
            cachedResults: Dictionary(
                uniqueKeysWithValues: messages.map {
                    (Self.cacheKey(messageID: $0.id, languageID: "fr"), Self.result(for: $0.id))
                }
            )
        )
        let viewModel = ThreadTranslationViewModel(handler: handler)

        await viewModel.prepare(messages: messages, configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.actionTitle, "Show Translation")
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Original restart-1")
        XCTAssertTrue(handler.translateCallIDs.isEmpty)

        viewModel.showTranslation()
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Translated restart-1")
    }

    func testCachedTranslationForDifferentSameIDBodyIsRejected() async {
        let message = Self.messages(count: 1, prefix: "cache-refresh")[0]
        let stale = Self.result(
            for: message.id,
            sourceBody: "Earlier body for the same ID"
        )
        let handler = RecordingThreadTranslationHandler(
            cachedResults: [
                Self.cacheKey(messageID: message.id, languageID: "fr"): stale,
            ]
        )
        let viewModel = ThreadTranslationViewModel(handler: handler)

        await viewModel.prepare(messages: [message], configuration: Self.french)

        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertEqual(
            viewModel.displayedBody(for: message).safeText,
            message.safeBodyText
        )
    }

    func testSameIDBodyRefreshNeverDisplaysCompletedStaleTranslation() async {
        let original = ThreadMessageModel(
            id: "same-id-after",
            sender: "sender@example.com",
            body: .plainText("Original body")
        )
        let refreshed = ThreadMessageModel(
            id: original.id,
            sender: original.sender,
            body: .plainText("Refreshed body")
        )
        let handler = RecordingThreadTranslationHandler(
            sourceFingerprints: [
                original.id: original.translationSourceFingerprint,
            ]
        )
        let viewModel = ThreadTranslationViewModel(handler: handler)

        await viewModel.translate(messages: [original], configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(
            viewModel.displayedBody(for: refreshed).safeText,
            "Refreshed body"
        )
    }

    func testSameIDBodyRefreshDoesNotCoalesceWithInFlightTranslation() async {
        let original = ThreadMessageModel(
            id: "same-id-during",
            sender: "sender@example.com",
            body: .plainText("Original body")
        )
        let refreshed = ThreadMessageModel(
            id: original.id,
            sender: original.sender,
            body: .plainText("Refreshed body")
        )
        let handler = RecordingThreadTranslationHandler(
            suspendedMessageIDs: [original.id],
            sourceFingerprints: [
                original.id: refreshed.translationSourceFingerprint,
            ]
        )
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let first = Task {
            await viewModel.translate(messages: [original], configuration: Self.french)
        }
        await handler.waitForCallCount(1)

        let second = Task {
            await viewModel.translate(messages: [refreshed], configuration: Self.french)
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let observedCallIDs = handler.translateCallIDs

        first.cancel()
        second.cancel()
        handler.resume(messageID: original.id)
        await first.value
        await second.value

        XCTAssertEqual(observedCallIDs, [original.id, refreshed.id])
    }

    func testTranslationReportsCompletedProgressWithoutPublishingPartialBodies() async {
        let handler = RecordingThreadTranslationHandler(suspendedMessageIDs: [
            "progress-1", "progress-2", "progress-3", "progress-4", "progress-5",
        ])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 5, prefix: "progress")
        let task = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }

        await handler.waitForCallCount(1)
        handler.resume(messageID: "progress-1")
        await handler.waitForCallCount(2)
        handler.resume(messageID: "progress-2")
        await handler.waitForCallCount(3)

        XCTAssertTrue(viewModel.isTranslating)
        XCTAssertEqual(viewModel.completedMessageCount, 2)
        XCTAssertEqual(viewModel.totalMessageCount, 5)
        XCTAssertEqual(viewModel.progressText, "2 of 5")
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertEqual(viewModel.displayMode, .original)

        task.cancel()
        await task.value
    }

    func testFailureKeepsEveryBodyOriginalAndRetryReusesSuccessfulSiblingCache() async {
        let handler = RecordingThreadTranslationHandler(failureCounts: ["retry-2": 1])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 3, prefix: "retry")

        await viewModel.translate(messages: messages, configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Original retry-1")
        XCTAssertEqual(viewModel.statusMessage, "Translation unavailable. Try again.")

        await viewModel.translate(messages: messages, configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .translated)
        XCTAssertEqual(handler.translateCallIDs, ["retry-1", "retry-2", "retry-2", "retry-3"])
        XCTAssertEqual(viewModel.displayedBody(for: messages[0]).safeText, "Translated retry-1")
    }

    func testEmptyConversationRemainsOriginalAndDoesNotStartWork() async {
        let handler = RecordingThreadTranslationHandler()
        let viewModel = ThreadTranslationViewModel(handler: handler)

        await viewModel.prepare(messages: [], configuration: Self.french)
        await viewModel.translate(messages: [], configuration: Self.french)

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertEqual(viewModel.completedMessageCount, 0)
        XCTAssertEqual(viewModel.totalMessageCount, 0)
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertTrue(handler.translateCallIDs.isEmpty)
    }

    func testLateCompletionAfterThreadChangeCannotReplaceCurrentBodies() async {
        let handler = RecordingThreadTranslationHandler(suspendedMessageIDs: ["old-1"])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let oldMessages = Self.messages(count: 1, prefix: "old")
        let newMessages = Self.messages(count: 2, prefix: "new")
        let oldTask = Task {
            await viewModel.translate(messages: oldMessages, configuration: Self.french)
        }
        await handler.waitForCallCount(1)

        await viewModel.prepare(messages: newMessages, configuration: Self.french)
        handler.resume(messageID: "old-1")
        await oldTask.value

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.totalMessageCount, 2)
        XCTAssertEqual(viewModel.displayedBody(for: newMessages[0]).safeText, "Original new-1")
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
    }

    func testLanguageChangeCancelsOldRequestAndClearsItsState() async {
        let handler = RecordingThreadTranslationHandler(suspendedMessageIDs: ["language-1"])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 1, prefix: "language")
        let task = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }
        await handler.waitForCallCount(1)

        viewModel.configurationDidChange()
        await viewModel.prepare(messages: messages, configuration: Self.german)
        handler.resume(messageID: "language-1")
        await task.value

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertNil(viewModel.statusMessage)
    }

    func testProviderReconfigurationCancelsOldRequestAndRequiresNewProviderCache() async {
        let oldHandler = RecordingThreadTranslationHandler(
            providerID: "provider-old",
            modelID: "model-old",
            suspendedMessageIDs: ["provider-1"]
        )
        let newHandler = RecordingThreadTranslationHandler(
            providerID: "provider-new",
            modelID: "model-new"
        )
        let viewModel = ThreadTranslationViewModel(handler: oldHandler)
        let messages = Self.messages(count: 1, prefix: "provider")
        let task = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }
        await oldHandler.waitForCallCount(1)

        viewModel.configure(handler: newHandler)
        oldHandler.resume(messageID: "provider-1")
        await task.value

        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertEqual(viewModel.actionTitle, "Translate")
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertNil(viewModel.statusMessage)
    }

    func testCallerCancellationBetweenMessagesStopsRemainingWorkAndKeepsOriginals() async {
        let handler = RecordingThreadTranslationHandler(suspendedMessageIDs: ["cancel-2"])
        let viewModel = ThreadTranslationViewModel(handler: handler)
        let messages = Self.messages(count: 3, prefix: "cancel")
        let task = Task {
            await viewModel.translate(messages: messages, configuration: Self.french)
        }
        await handler.waitForCallCount(2)

        task.cancel()
        await task.value

        XCTAssertEqual(handler.translateCallIDs, ["cancel-1", "cancel-2"])
        XCTAssertEqual(viewModel.displayMode, .original)
        XCTAssertTrue(viewModel.translatedBodies.isEmpty)
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.statusMessage)
    }

    private static let french = ThreadTranslationConfiguration(
        targetLanguageID: "fr",
        targetLanguageName: "French"
    )
    private static let german = ThreadTranslationConfiguration(
        targetLanguageID: "de",
        targetLanguageName: "German"
    )

    private static func messages(count: Int, prefix: String) -> [ThreadMessageModel] {
        (1...count).map {
            ThreadMessageModel(
                id: "\(prefix)-\($0)",
                sender: "sender@example.com",
                body: .plainText("Original \(prefix)-\($0)")
            )
        }
    }

    private static func result(
        for messageID: String,
        providerID: String = "provider",
        modelID: String = "model",
        languageID: String = "fr",
        sourceBody: String? = nil
    ) -> MessageTranslationResult {
        MessageTranslationResult(
            messageID: MessageID(messageID),
            renderedBody: RenderedEmailBody(
                kind: .plainText,
                safeText: "Translated \(messageID)",
                blockedRemoteImageURLs: []
            ),
            sourceFingerprint: MailTranslationFingerprint.source(
                messageID: MessageID(messageID),
                body: .plainText(sourceBody ?? "Original \(messageID)")
            ),
            providerID: providerID,
            modelID: modelID,
            targetLanguageID: languageID,
            wasCached: false
        )
    }

    private static func cacheKey(messageID: String, languageID: String) -> String {
        "\(messageID)|\(languageID)"
    }
}

private final class RecordingThreadTranslationHandler: ThreadTranslationHandling, @unchecked Sendable {
    let providerID: String
    let modelID: String
    private let state: RecordingThreadTranslationState

    init(
        providerID: String = "provider",
        modelID: String = "model",
        cachedResults: [String: MessageTranslationResult] = [:],
        failureCounts: [String: Int] = [:],
        suspendedMessageIDs: Set<String> = [],
        sourceFingerprints: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.state = RecordingThreadTranslationState(
            cachedResults: cachedResults,
            failureCounts: failureCounts,
            suspendedMessageIDs: suspendedMessageIDs,
            sourceFingerprints: sourceFingerprints
        )
    }

    var translateCallIDs: [String] {
        state.translateCallIDs
    }

    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> MessageTranslationResult? {
        state.cachedTranslation(messageID: messageID, targetLanguageID: targetLanguageID)
    }

    func translate(
        messageID: MessageID,
        targetLanguageID: String,
        targetLanguageName: String
    ) async throws -> MessageTranslationResult {
        try await state.translate(
            messageID: messageID,
            targetLanguageID: targetLanguageID,
            providerID: providerID,
            modelID: modelID
        )
    }

    func waitForCallCount(_ count: Int) async {
        while translateCallIDs.count < count {
            await Task.yield()
        }
    }

    func resume(messageID: String) {
        state.resume(messageID: messageID)
    }
}

private final class RecordingThreadTranslationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: MessageTranslationResult]
    private var remainingFailureCounts: [String: Int]
    private var suspendedMessageIDs: Set<String>
    private let sourceFingerprints: [String: String]
    private var continuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private var calls: [String] = []

    init(
        cachedResults: [String: MessageTranslationResult],
        failureCounts: [String: Int],
        suspendedMessageIDs: Set<String>,
        sourceFingerprints: [String: String]
    ) {
        self.cache = cachedResults
        self.remainingFailureCounts = failureCounts
        self.suspendedMessageIDs = suspendedMessageIDs
        self.sourceFingerprints = sourceFingerprints
    }

    var translateCallIDs: [String] {
        lock.withLock { calls }
    }

    func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) -> MessageTranslationResult? {
        lock.withLock {
            cache["\(messageID.rawValue)|\(targetLanguageID)"]
        }
    }

    func translate(
        messageID: MessageID,
        targetLanguageID: String,
        providerID: String,
        modelID: String
    ) async throws -> MessageTranslationResult {
        let id = messageID.rawValue
        let shouldSuspend = lock.withLock {
            calls.append(id)
            return suspendedMessageIDs.contains(id)
        }
        if shouldSuspend {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled = lock.withLock {
                        if Task.isCancelled {
                            return true
                        }
                        continuations[id] = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let continuation = self.lock.withLock {
                    self.suspendedMessageIDs.remove(id)
                    return self.continuations.removeValue(forKey: id)
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        let shouldFail = lock.withLock {
            let remaining = remainingFailureCounts[id, default: 0]
            if remaining > 0 {
                remainingFailureCounts[id] = remaining - 1
                return true
            }
            return false
        }
        if shouldFail {
            throw TestTranslationError.failed
        }
        let result = MessageTranslationResult(
            messageID: messageID,
            renderedBody: RenderedEmailBody(
                kind: .plainText,
                safeText: "Translated \(id)",
                blockedRemoteImageURLs: []
            ),
            sourceFingerprint: sourceFingerprints[id]
                ?? MailTranslationFingerprint.source(
                    messageID: messageID,
                    body: .plainText("Original \(id)")
                ),
            providerID: providerID,
            modelID: modelID,
            targetLanguageID: targetLanguageID,
            wasCached: false
        )
        lock.withLock {
            cache["\(id)|\(targetLanguageID)"] = result
        }
        return result
    }

    func resume(messageID: String) {
        let continuation = lock.withLock {
            suspendedMessageIDs.remove(messageID)
            return continuations.removeValue(forKey: messageID)
        }
        continuation?.resume()
    }
}

private enum TestTranslationError: Error {
    case failed
}
