import Foundation
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB

final class LocalMailTranslationServiceTests: XCTestCase {
    func testSecondTranslationUsesValidatedCacheWithoutCallingProviderAgain() async throws {
        let message = Self.message(body: "Hallo Welt")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()
        let service = LocalMailTranslationService(provider: provider, store: store)
        let input = Self.input(messageID: message.id)

        let first = try await service.translateMessage(input, actor: Self.actor)
        let second = try await service.translateMessage(input, actor: Self.actor)

        XCTAssertEqual(provider.translationCallCount, 1)
        XCTAssertEqual(first.renderedBody, second.renderedBody)
        XCTAssertFalse(first.wasCached)
        XCTAssertTrue(second.wasCached)
    }

    func testPlainTextCacheHitPreservesTranslatedWhitespaceExactly() async throws {
        let message = Self.message(body: "Hallo Welt")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider(
            fixedTranslation: "R&D <ready> > done\n"
        )
        let service = LocalMailTranslationService(provider: provider, store: store)
        let input = Self.input(messageID: message.id)

        let first = try await service.translateMessage(input, actor: Self.actor)
        let second = try await service.translateMessage(input, actor: Self.actor)

        XCTAssertEqual(first.renderedBody.safeText, "R&D <ready> > done\n")
        XCTAssertEqual(second.renderedBody, first.renderedBody)
        XCTAssertTrue(second.wasCached)
    }

    func testHTMLCacheHitMatchesFreshTranslatedBodyExactly() async throws {
        let message = Self.message(
            body: "Hallo",
            bodyHTML: #"<p>Hallo</p><img src="https://tracker.example/pixel.png">"#
        )
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider(fixedTranslation: "*|RECIPIENT|*")
        let service = LocalMailTranslationService(provider: provider, store: store)
        let input = Self.input(messageID: message.id)

        let first = try await service.translateMessage(input, actor: Self.actor)
        let second = try await service.translateMessage(input, actor: Self.actor)

        XCTAssertEqual(
            first.renderedBody.safeHTML,
            #"<p>*|RECIPIENT|*</p><img src="https://tracker.example/pixel.png">"#
        )
        XCTAssertEqual(second.renderedBody, first.renderedBody)
        XCTAssertTrue(second.wasCached)
    }

    func testSourceChangeInvalidatesCachedTranslation() async throws {
        let original = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [original])
        let provider = RecordingTranslationProvider()
        let service = LocalMailTranslationService(provider: provider, store: store)
        let input = Self.input(messageID: original.id)
        _ = try await service.translateMessage(input, actor: Self.actor)
        store.cacheMessage(Self.message(body: "Guten Tag"))

        let result = try await service.translateMessage(input, actor: Self.actor)

        XCTAssertEqual(provider.translationCallCount, 2)
        XCTAssertFalse(result.wasCached)
        XCTAssertEqual(result.renderedBody.safeText, "[en] Guten Tag")
    }

    func testSameIDSourceMutationDuringProviderCallIsRejectedWithoutCaching() async throws {
        let original = Self.message(body: "Hallo")
        let refreshed = Self.message(body: "Guten Tag")
        let store = InMemoryMailStore(messages: [original])
        let provider = RecordingTranslationProvider(
            onTranslationRequest: {
                store.cacheMessage(refreshed)
            }
        )
        let service = LocalMailTranslationService(provider: provider, store: store)

        do {
            _ = try await service.translateMessage(
                Self.input(messageID: original.id),
                actor: Self.actor
            )
            XCTFail("Expected source mutation validation failure")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Message changed during translation.")
            )
        }

        XCTAssertNil(
            try store.cachedTranslation(
                messageID: original.id,
                targetLanguageID: "en"
            )
        )
    }

    func testMutationBetweenServiceCheckAndRepositoryWriteIsRejectedAtomically() async throws {
        let original = Self.message(body: "Hallo")
        let refreshed = Self.message(body: "Guten Tag")
        let sourceMutator = TranslationSourceMutator(message: refreshed)
        let store = InMemoryMailStore(
            messages: [original],
            onTranslationCompareAndSaveBeforeLock: {
                sourceMutator.mutate()
            },
            onTranslationSaveAfterActiveCheck: {},
            onMessageDeleteBeforeTranslationCacheMutation: {}
        )
        sourceMutator.setStore(store)
        let provider = RecordingTranslationProvider()
        let service = LocalMailTranslationService(provider: provider, store: store)

        do {
            _ = try await service.translateMessage(
                Self.input(messageID: original.id),
                actor: Self.actor
            )
            XCTFail("Expected atomic source mutation rejection")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Message changed during translation.")
            )
        }

        XCTAssertNil(
            try store.cachedTranslation(
                messageID: original.id,
                targetLanguageID: "en"
            )
        )
    }

    func testConcurrentLateSourceANeverOverwritesCompletedSourceBTranslation() async throws {
        let sourceA = Self.message(body: "Source A")
        let sourceB = Self.message(body: "Source B")
        let gate = TranslationCompareAndSaveRaceGate()
        let store = InMemoryMailStore(
            messages: [sourceA],
            onTranslationCompareAndSaveBeforeLock: {
                gate.pauseFirstSave()
            },
            onTranslationSaveAfterActiveCheck: {},
            onMessageDeleteBeforeTranslationCacheMutation: {}
        )
        let provider = RecordingTranslationProvider()
        let lateSourceAService = TranslationServiceBox(
            LocalMailTranslationService(provider: provider, store: store)
        )
        let sourceBService = LocalMailTranslationService(provider: provider, store: store)
        let sourceAInput = Self.input(messageID: sourceA.id)
        let actor = Self.actor
        let lateSourceATask = Task.detached {
            try await lateSourceAService.translateMessage(
                sourceAInput,
                actor: actor
            )
        }

        XCTAssertEqual(gate.firstSavePaused.wait(timeout: .now() + 2), .success)
        defer { gate.resumeFirstSave.signal() }
        store.cacheMessage(sourceB)

        let sourceBResult = try await sourceBService.translateMessage(
            Self.input(messageID: sourceB.id),
            actor: Self.actor
        )
        XCTAssertEqual(sourceBResult.sourceFingerprint, MailTranslationFingerprint.message(sourceB))
        XCTAssertEqual(sourceBResult.renderedBody.safeText, "[en] Source B")

        gate.resumeFirstSave.signal()
        switch await lateSourceATask.result {
        case .success:
            XCTFail("Expected the late source-A translation to be rejected")
        case let .failure(error):
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Message changed during translation.")
            )
        }

        let cached = try XCTUnwrap(
            store.cachedTranslation(messageID: sourceB.id, targetLanguageID: "en")
        )
        XCTAssertEqual(cached.sourceFingerprint, MailTranslationFingerprint.message(sourceB))
        XCTAssertEqual(cached.translatedBody, "[en] Source B")
    }

    func testPlainTextCodeFormsNeverReachProviderAndRemainByteExact() async throws {
        let source = """
        Translate this.
            let token = "do-not-translate"
        Keep `inline()` unchanged.
        Translate that.
        """
        let message = Self.message(body: source)
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()

        let result = try await LocalMailTranslationService(provider: provider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        XCTAssertFalse(provider.requestedText.contains("do-not-translate"))
        XCTAssertFalse(provider.requestedText.contains("inline()"))
        XCTAssertTrue(result.renderedBody.safeText.contains(
            #"    let token = "do-not-translate""#
        ))
        XCTAssertTrue(result.renderedBody.safeText.contains("`inline()`"))
    }

    func testTargetChangeDoesNotReuseOtherLanguageCache() async throws {
        let message = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()
        let service = LocalMailTranslationService(provider: provider, store: store)
        _ = try await service.translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        let result = try await service.translateMessage(
            TranslateMessageInput(
                messageID: message.id,
                targetLanguageID: "fr",
                targetLanguageName: "French"
            ),
            actor: Self.actor
        )

        XCTAssertEqual(provider.translationCallCount, 2)
        XCTAssertEqual(result.targetLanguageID, "fr")
        XCTAssertEqual(result.renderedBody.safeText, "[fr] Hallo")
    }

    func testProviderAndModelChangesInvalidateCachedTranslation() async throws {
        let message = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [message])
        let firstProvider = RecordingTranslationProvider(id: "provider-a", chatModelID: "model-a")
        _ = try await LocalMailTranslationService(provider: firstProvider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        let changedProvider = RecordingTranslationProvider(id: "provider-b", chatModelID: "model-a")
        let providerResult = try await LocalMailTranslationService(provider: changedProvider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)
        let changedModel = RecordingTranslationProvider(id: "provider-b", chatModelID: "model-b")
        let modelResult = try await LocalMailTranslationService(provider: changedModel, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        XCTAssertEqual(changedProvider.translationCallCount, 1)
        XCTAssertEqual(changedModel.translationCallCount, 1)
        XCTAssertFalse(providerResult.wasCached)
        XCTAssertFalse(modelResult.wasCached)
    }

    func testPreviousContractVersionInvalidatesCachedTranslation() async throws {
        let message = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()
        let staleTranslation = CachedMessageTranslation(
            messageID: message.id,
            targetLanguageID: "en",
            sourceFingerprint: MailTranslationFingerprint.message(message),
            providerID: provider.id,
            modelID: provider.chatModelID,
            contractVersion: "message-translation-v1",
            bodyKind: .plainText,
            translatedBody: "stale",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                staleTranslation,
                expectedSourceFingerprint: staleTranslation.sourceFingerprint
            ),
            .saved
        )

        let result = try await LocalMailTranslationService(provider: provider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        XCTAssertEqual(provider.translationCallCount, 1)
        XCTAssertFalse(result.wasCached)
        XCTAssertEqual(result.renderedBody.safeText, "[en] Hallo")
    }

    func testMalformedReturnedSegmentIDsThrowWithoutCaching() async throws {
        let message = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider(returnMalformedIDs: true)
        let service = LocalMailTranslationService(provider: provider, store: store)
        let input = Self.input(messageID: message.id)

        do {
            _ = try await service.translateMessage(input, actor: Self.actor)
            XCTFail("Expected invalid segment identity")
        } catch {
            XCTAssertEqual(error as? MailTranslationDocumentError, .invalidSegmentIdentity)
        }

        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testSingleBatchModelMismatchThrowsWithoutCaching() async throws {
        let message = Self.message(body: "Hallo")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider(responseModelIDs: ["unexpected-model"])

        do {
            _ = try await LocalMailTranslationService(provider: provider, store: store)
                .translateMessage(Self.input(messageID: message.id), actor: Self.actor)
            XCTFail("Expected response model validation failure")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed(
                    "Translation response model does not match the configured provider model."
                )
            )
        }

        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testLaterBatchModelMismatchThrowsWithoutCachingPartialTranslation() async throws {
        let first = String(repeating: "a", count: 5_000)
        let second = String(repeating: "b", count: 5_000)
        let message = Self.message(
            body: "\(first)\n\(second)",
            bodyHTML: "<p>\(first)</p><p>\(second)</p>"
        )
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider(
            responseModelIDs: ["recording-model", "unexpected-model"]
        )

        do {
            _ = try await LocalMailTranslationService(provider: provider, store: store)
                .translateMessage(Self.input(messageID: message.id), actor: Self.actor)
            XCTFail("Expected response model validation failure")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed(
                    "Translation response model does not match the configured provider model."
                )
            )
        }

        XCTAssertEqual(provider.translationCallCount, 2)
        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testEmptyEligibleContentSkipsProvider() async throws {
        let message = Self.message(body: " \n\t ")
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()

        let result = try await LocalMailTranslationService(provider: provider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        XCTAssertEqual(provider.translationCallCount, 0)
        XCTAssertEqual(result.renderedBody.safeText, " \n\t ")
    }

    func testMultiBatchTranslationSavesOneCompleteCacheEntry() async throws {
        let first = String(repeating: "a", count: 5_000)
        let second = String(repeating: "b", count: 5_000)
        let message = Self.message(
            body: "\(first)\n\(second)",
            bodyHTML: "<p>\(first)</p><p>\(second)</p>"
        )
        let saveCounter = LockedCounter()
        let store = InMemoryMailStore(
            messages: [message],
            onTranslationSaveAfterActiveCheck: { saveCounter.increment() },
            onMessageDeleteBeforeTranslationCacheMutation: {}
        )
        let provider = RecordingTranslationProvider()

        let result = try await LocalMailTranslationService(provider: provider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)
        let cached = try XCTUnwrap(
            store.cachedTranslation(messageID: message.id, targetLanguageID: "en")
        )

        XCTAssertGreaterThan(provider.translationCallCount, 1)
        XCTAssertEqual(saveCounter.value, 1)
        XCTAssertEqual(cached.translatedBody, result.renderedBody.safeHTML)
        XCTAssertTrue(cached.translatedBody.contains("[en] \(first)"))
        XCTAssertTrue(cached.translatedBody.contains("[en] \(second)"))
    }

    func testTranslationBatchesReserveHalfTheContextForPromptAndResponse() async throws {
        let paragraphs = (0..<6).map { index in
            "<p>\(String(repeating: String(index), count: 1_000))</p>"
        }.joined()
        let message = Self.message(body: "Large email", bodyHTML: paragraphs)
        let store = InMemoryMailStore(messages: [message])
        let provider = RecordingTranslationProvider()

        _ = try await LocalMailTranslationService(provider: provider, store: store)
            .translateMessage(Self.input(messageID: message.id), actor: Self.actor)

        XCTAssertEqual(provider.translationCallCount, 3)
        XCTAssertTrue(
            provider.requestedUTF8ByteCounts.allSatisfy {
                $0 <= provider.capabilities.maxContextTokens / 2
            }
        )
    }

    private static let actor = Actor(
        id: "local-user",
        kind: .user,
        displayName: "Local User",
        permissions: .guiUser
    )

    private static func input(messageID: MessageID) -> TranslateMessageInput {
        TranslateMessageInput(
            messageID: messageID,
            targetLanguageID: "en",
            targetLanguageName: "English"
        )
    }

    private static func message(
        body: String,
        bodyHTML: String? = nil
    ) -> MessageSummary {
        MessageSummary(
            id: MessageID("msg-translation"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translate",
            preview: String(body.prefix(80)),
            body: body,
            bodyHTML: bodyHTML,
            smartCategory: .personal
        )
    }
}

private final class RecordingTranslationProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName = "Recording Translation"
    let chatModelID: String
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: true,
        supportsStreaming: false,
        maxContextTokens: 4096,
        runsLocally: true
    )

    private let lock = NSLock()
    private var translationRequests: [AITranslationRequest] = []
    private let returnMalformedIDs: Bool
    private let fixedTranslation: String?
    private let responseModelIDs: [String]
    private let onTranslationRequest: () -> Void

    init(
        id: String = "recording",
        chatModelID: String = "recording-model",
        returnMalformedIDs: Bool = false,
        fixedTranslation: String? = nil,
        responseModelIDs: [String] = [],
        onTranslationRequest: @escaping () -> Void = {}
    ) {
        self.id = id
        self.chatModelID = chatModelID
        self.returnMalformedIDs = returnMalformedIDs
        self.fixedTranslation = fixedTranslation
        self.responseModelIDs = responseModelIDs
        self.onTranslationRequest = onTranslationRequest
    }

    var translationCallCount: Int {
        lock.withLock { translationRequests.count }
    }

    var requestedText: String {
        lock.withLock {
            translationRequests.flatMap(\.segments).map(\.text).joined()
        }
    }

    var requestedUTF8ByteCounts: [Int] {
        lock.withLock {
            translationRequests.map { request in
                request.segments.reduce(0) { $0 + $1.text.utf8.count }
            }
        }
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        throw AIProviderError.unavailable
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        let responseModelID = lock.withLock {
            let callIndex = translationRequests.count
            translationRequests.append(request)
            return responseModelIDs.indices.contains(callIndex)
                ? responseModelIDs[callIndex]
                : chatModelID
        }
        onTranslationRequest()
        let segments = request.segments.enumerated().map { index, segment in
            AITranslatedSegment(
                id: returnMalformedIDs && index == 0 ? "wrong-id" : segment.id,
                translation: fixedTranslation ?? "[\(request.targetLanguageID)] \(segment.text)"
            )
        }
        return AITranslationResponse(segments: segments, modelID: responseModelID, localOnly: true)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class TranslationSourceMutator: @unchecked Sendable {
    private let lock = NSLock()
    private let message: MessageSummary
    private var store: InMemoryMailStore?

    init(message: MessageSummary) {
        self.message = message
    }

    func setStore(_ store: InMemoryMailStore) {
        lock.withLock {
            self.store = store
        }
    }

    func mutate() {
        let currentStore: InMemoryMailStore? = lock.withLock { self.store }
        currentStore?.cacheMessage(message)
    }
}

private final class TranslationCompareAndSaveRaceGate: @unchecked Sendable {
    let firstSavePaused = DispatchSemaphore(value: 0)
    let resumeFirstSave = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var saveCount = 0

    func pauseFirstSave() {
        let isFirstSave = lock.withLock {
            saveCount += 1
            return saveCount == 1
        }
        guard isFirstSave else { return }
        firstSavePaused.signal()
        _ = resumeFirstSave.wait(timeout: .now() + 2)
    }
}

private final class TranslationServiceBox: @unchecked Sendable {
    let service: LocalMailTranslationService<InMemoryMailStore>

    init(_ service: LocalMailTranslationService<InMemoryMailStore>) {
        self.service = service
    }

    func translateMessage(
        _ input: TranslateMessageInput,
        actor: Actor
    ) async throws -> MessageTranslationResult {
        try await service.translateMessage(input, actor: actor)
    }
}
