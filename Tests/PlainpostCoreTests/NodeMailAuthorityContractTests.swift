import Foundation
import PlainpostAccountProtocol
import XCTest
@testable import PlainpostCore

final class NodeMailAuthorityContractTests: XCTestCase {
    func testAuthorityIsACompositeOfIndependentCapabilities() async throws {
        let snapshots = SnapshotFixture()
        let search = SearchFixture()
        let messages = MessageFixture()
        let mutations = MutationFixture()
        let attachments = AttachmentFixture()
        let authority = ContractAuthority(
            snapshots: snapshots,
            search: search,
            messages: messages,
            mutations: mutations,
            attachments: attachments
        )

        let page = try await authority.snapshots.snapshot(after: nil, limit: 25)
        XCTAssertEqual(page.messages.count, 1)
        let message = try await authority.messages.message(id: MessageID("message-1"))
        XCTAssertEqual(message.id, MessageID("message-1"))
        let mutation = try await authority.mutations.apply(canonicalOperation: Data([1]))
        XCTAssertEqual(mutation.state, "applied")
        let attachment = try await authority.attachments.attachment(id: "attachment-1")
        XCTAssertEqual(attachment.metadata.id, "attachment-1")
        let indexState = await authority.search.indexState()
        XCTAssertEqual(indexState, .ready)
    }
}

private struct ContractAuthority: PlainpostMailAuthority {
    let snapshots: any MailSnapshotServing
    let search: any MailSearchService
    let messages: any MailMessageServing
    let mutations: any MailMutationServing
    let attachments: any MailAttachmentServing
}

private struct SnapshotFixture: MailSnapshotServing {
    func snapshot(after: MailSearchCursor?, limit: Int) async throws -> MailSnapshotPage {
        MailSnapshotPage(messages: [MessageSummary(id: MessageID("message-1"), threadID: nil, from: EmailAddress("from@example.com"), subject: "Subject", preview: "Preview", smartCategory: .unknown)], nextCursor: nil, revision: "1")
    }
}

private struct SearchFixture: MailSearchService {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse { fatalError("not used") }
    func suggestions(_ request: MailSearchSuggestionRequest) async throws -> [MailSearchSuggestionSection] { [] }
    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}
    func performMaintenanceIfDue(now: Date) async throws {}
}

private struct MessageFixture: MailMessageServing {
    func message(id: MessageID) async throws -> MessageSummary {
        MessageSummary(id: id, threadID: nil, from: EmailAddress("from@example.com"), subject: "Subject", preview: "Preview", smartCategory: .unknown)
    }
}

private struct MutationFixture: MailMutationServing {
    func apply(canonicalOperation: Data) async throws -> MailMutationResult { MailMutationResult(idempotencyKey: "key", state: "applied") }
}

private struct AttachmentFixture: MailAttachmentServing {
    func attachment(id: String) async throws -> MailAttachmentStream {
        let stream = PlainpostByteStream(capacity: 1)
        let producer = stream.producer
        Task { try? await producer.send(Data([1])); producer.finish() }
        return MailAttachmentStream(metadata: MailAttachment(id: id, filename: "file.txt", mimeType: "text/plain", disposition: "attachment", byteCount: 1, contentDigest: nil), bytes: stream)
    }
}
