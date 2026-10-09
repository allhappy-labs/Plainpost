import Foundation
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI

/// Offline (cached read-only) Ask Mail: the account guard, the local-only guard and the
/// ownership check on every referenced message.
final class CachedMailAskMailServiceTests: XCTestCase {
    private var url: URL!
    private var store: SQLiteMailStore!
    private let accountA = AccountID("cached-a")
    private let accountB = AccountID("cached-b")

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cached-ask-mail-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([accountA, accountB].map { id in
            Account(id: id, displayName: id.rawValue, email: EmailAddress("\(id.rawValue)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        })
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func commit(_ id: String, body: String, to account: AccountID, uid: Int) throws {
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress("lena@example.com"),
                           fromDisplayName: "Lena", subject: "Flat deposit", preview: body,
                           smartCategory: .personal, labels: [], isSeen: true, mailboxPath: "INBOX",
                           isDeleted: false, body: body, sentAt: Date(timeIntervalSince1970: 1_790_000_000)),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account, mailboxPath: "INBOX", uidValidity: 1, uid: uid, notificationEligible: false)
    }

    private func service(_ provider: CachedScriptedProvider = CachedScriptedProvider(), account: AccountID?,
                         requiresAccountScope: Bool = true) -> CachedMailAskMailService {
        CachedMailAskMailService(provider: provider, store: store, selectedAccountID: account,
                                 requiresAccountScope: requiresAccountScope)
    }

    private func ask(_ service: CachedMailAskMailService) async throws -> MailboxQuestionAnswer {
        try await service.ask(question: "What did Lena say about the flat deposit?", scope: .allMail,
                              activeContext: nil, priorTurns: [])
    }

    func testOwnEvidenceIsAnswered() async throws {
        try commit("mine", body: "The flat deposit is due on Friday.", to: accountA, uid: 1)
        let answer = try await ask(service(account: accountA))
        XCTAssertEqual(answer.sources.map(\.messageID), [MessageID("mine")])
    }

    func testSearchNeverSurfacesMessagesSharedWithAnotherAccount() async throws {
        // Filed under both accounts: the full ownership check says it belongs to neither.
        try commit("shared", body: "The flat deposit is due on Friday.", to: accountA, uid: 1)
        try commit("shared", body: "The flat deposit is due on Friday.", to: accountB, uid: 2)
        XCTAssertFalse(try store.accountMessageIDs(accountID: accountA).contains(MessageID("shared")))
        let answer = try await ask(service(account: accountA))
        XCTAssertFalse(answer.sources.contains { $0.messageID == MessageID("shared") })
        XCTAssertFalse(answer.askMailAnswer?.referencedMessageIDs.contains(MessageID("shared")) ?? false)
    }

    private func foreignSource() -> MailKnowledgeSource {
        MailKnowledgeSource(id: "S1", messageID: MessageID("theirs"), conversationKey: "message_theirs",
                            mailboxPath: "INBOX", subject: "Flat deposit", sender: "Lena", sentAt: nil,
                            snippet: "The flat deposit is due on Friday.")
    }

    private func serviceAnswering(_ answer: MailboxQuestionAnswer) -> CachedMailAskMailService {
        CachedMailAskMailService(provider: CachedScriptedProvider(), store: store, selectedAccountID: accountA,
                                 requiresAccountScope: true, answerer: { _, _ in answer })
    }

    func testForeignCitedEvidenceIsRejected() async throws {
        try commit("mine", body: "Mine.", to: accountA, uid: 1)
        try commit("theirs", body: "The flat deposit is due on Friday.", to: accountB, uid: 2)
        let answer = MailboxQuestionAnswer(
            answer: "Due Friday [S1].", sources: [foreignSource()], insufficientEvidence: false,
            providerName: "p", modelID: "m", localOnly: true, retrievalMode: .lexical)
        do {
            _ = try await ask(serviceAnswering(answer))
            XCTFail("Expected the ownership check")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .permissionDenied("Mailbox answer contains another account's evidence."))
        }
    }

    func testForeignBlockMessageIsRejected() async throws {
        try commit("mine", body: "Mine.", to: accountA, uid: 1)
        try commit("theirs", body: "The flat deposit is due on Friday.", to: accountB, uid: 2)
        let draft = AskMailDraftBlock(id: "d", replyToMessageID: MessageID("theirs"), recipientName: "Lena",
                                      recipientAddress: "lena@example.com", subject: "Re: Flat deposit", body: "Thanks")
        let answer = MailboxQuestionAnswer(
            answer: "Here's a draft.", sources: [], insufficientEvidence: false,
            providerName: "p", modelID: "m", localOnly: true, retrievalMode: .lexical,
            askMailAnswer: AskMailAnswer(text: "Here's a draft.", blocks: [.draft(draft)]))
        do {
            _ = try await ask(serviceAnswering(answer))
            XCTFail("Expected the ownership check")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .permissionDenied("Mailbox answer contains another account's evidence."))
        }
    }

    func testMissingAccountIsRefusedBeforeAnySearch() async throws {
        try commit("mine", body: "The flat deposit is due on Friday.", to: accountA, uid: 1)
        let provider = CachedScriptedProvider()
        do {
            _ = try await ask(service(provider, account: nil))
            XCTFail("Expected the account guard")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .permissionDenied("Select a mail account before asking about mail."))
        }
        XCTAssertEqual(provider.calls.value, 0)
    }

    func testRemoteProviderIsRefused() async throws {
        try commit("mine", body: "The flat deposit is due on Friday.", to: accountA, uid: 1)
        let provider = CachedScriptedProvider(runsLocally: false)
        do {
            _ = try await ask(service(provider, account: accountA))
            XCTFail("Expected the local-only guard")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .remoteEndpointDisallowed)
        }
        XCTAssertEqual(provider.calls.value, 0)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct CachedScriptedProvider: AIProvider {
    let id = "cached-scripted"; let displayName = "Cached scripted"; let chatModelID = "cached-1"
    let capabilities: AICapabilities
    let calls = CallCounter()
    init(runsLocally: Bool = true) {
        capabilities = AICapabilities(supportsChat: true, supportsEmbeddings: false, supportsJSONMode: true,
                                      supportsStreaming: false, maxContextTokens: 4096, runsLocally: runsLocally)
    }
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        calls.increment()
        return AIGenerationResponse(text: "The flat deposit is due on Friday [S1].", modelID: chatModelID, localOnly: true)
    }
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        calls.increment()
        throw AIProviderError.unavailable
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}
