import Foundation
import PlainpostCore

public final class DurableMailEmbeddingIndexer<Store: MailKnowledgeRepository>: @unchecked Sendable {
    private let provider: any AIProvider
    private let store: Store

    public init(provider: any AIProvider, store: Store) {
        self.provider = provider
        self.store = store
    }

    @discardableResult
    public func rebuild(
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int {
        guard provider.capabilities.supportsEmbeddings else { return 0 }
        let messages = store.messages.filter { !$0.isDeleted }
        guard let firstMessage = messages.first,
              let firstText = MailEmbeddingContent.chunks(for: firstMessage).first
        else { return 0 }
        let seedEmbedding = try await provider.embed(AIEmbeddingRequest(text: firstText))
        let modelID = seedEmbedding.modelID
        let existing = Dictionary(
            grouping: try store.storedMailEmbeddingChunks(providerID: provider.id, modelID: modelID),
            by: \.messageID
        )
        var indexed = 0

        for (offset, message) in messages.enumerated() {
            try Task.checkCancellation()
            let fingerprint = MailEmbeddingContent.fingerprint(for: message)
            if existing[message.id]?.contains(where: { $0.contentFingerprint == fingerprint }) == true {
                indexed += 1
                progress(offset + 1, messages.count)
                continue
            }
            let texts = MailEmbeddingContent.chunks(for: message)
            var chunks: [StoredMailEmbeddingChunk] = []
            for (ordinal, text) in texts.enumerated() {
                try Task.checkCancellation()
                let embedding = offset == 0 && ordinal == 0
                    ? seedEmbedding
                    : try await provider.embed(AIEmbeddingRequest(text: text))
                guard embedding.modelID == modelID else { continue }
                chunks.append(
                    StoredMailEmbeddingChunk(
                        messageID: message.id,
                        providerID: provider.id,
                        modelID: modelID,
                        contentFingerprint: fingerprint,
                        ordinal: ordinal,
                        text: text,
                        vector: embedding.vector
                    )
                )
            }
            try store.replaceMailEmbeddingChunks(
                messageID: message.id,
                providerID: provider.id,
                modelID: modelID,
                contentFingerprint: fingerprint,
                chunks: chunks
            )
            indexed += 1
            progress(offset + 1, messages.count)
        }
        return indexed
    }
}

enum MailEmbeddingContent {
    static func chunks(for message: MessageSummary) -> [String] {
        let source = "From: \(message.from.rawValue)\nSubject: \(message.subject)\n\(message.body)"
        let characters = Array(source.prefix(24_000))
        guard !characters.isEmpty else { return [message.preview] }
        let size = 1_200
        let step = 1_050
        return stride(from: 0, to: characters.count, by: step).map { start in
            String(characters[start..<min(start + size, characters.count)])
        }
    }

    static func fingerprint(for message: MessageSummary) -> String {
        let value = "\(message.from.rawValue)\u{1F}\(message.subject)\u{1F}\(message.body)"
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
